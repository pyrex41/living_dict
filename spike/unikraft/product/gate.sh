#!/bin/sh
set -eu

PRODUCT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$PRODUCT_DIR/build"
BINARY="$BUILD_DIR/ld-kv"
BASE_KERNEL="$BUILD_DIR/base-kernel"
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/livingdict-kv.XXXXXX")
trap 'rm -rf "$RUN_DIR"' EXIT HUP INT TERM

fail()
{
	printf 'product-gate: %s\n' "$*" >&2
	exit 1
}

# Static policy check: neither native nor loader packaging may acquire these.
if grep -Eiq 'ukrandom|lwip|(^|[^[:alnum:]_])clock([^[:alnum:]_]|$)|scheduler|9p' \
	"$PRODUCT_DIR/Kraftfile" "$PRODUCT_DIR/loader/Kraftfile"; then
	fail "forbidden capability in a Kraftfile"
fi

mkdir -p "$BUILD_DIR"
x86_64-unknown-linux-musl-gcc \
	-std=c11 -O2 -static-pie -fPIE -Wall -Wextra -Werror \
	-o "$BINARY" "$PRODUCT_DIR/main.c"

case "$(file "$BINARY")" in
	*"ELF 64-bit"*"x86-64"*"static-pie"*) ;;
	*) fail "cross build did not produce an x86_64 static PIE" ;;
esac

hash_file()
{
	shasum -a 256 "$1" | awk '{print $1}'
}

semantic_frames()
{
	expected=$1
	raw=$2
	first=$(sed -n '1p' "$expected")
	awk -v first="$first" '
		{sub(/\r$/, "")}
		!started && $0 == first { started=1 }
		started { print }
		started && $0 == "HALT" { exit }
	' "$raw"
}

prepare_runtime()
{
	# KraftKit 0.12.15 cannot keep a Linux process attached to its QEMU
	# serial console: its runner daemonizes QEMU and redirects serial output.
	# Let Kraft resolve and unpack the catalog runtime, then boot that exact
	# kernel in the foreground with the QEMU command line Kraft generated.
	machine="ld-kv-gate-$$"
	mkdir -p "$RUN_DIR/kraft-tmp"
	# Kraft requires the declared rootfs directory to exist even though this
	# resolution-only machine is never started and the real fixture initrd is
	# assembled below.
	mkdir -p "$PRODUCT_DIR/loader/rootfs"
	(
		cd "$PRODUCT_DIR/loader"
		TMPDIR="$RUN_DIR/kraft-tmp" kraft --no-prompt --no-emojis \
			--log-type basic run --plat qemu --arch x86_64 -W \
			--no-start --name "$machine" --memory 64Mi >/dev/null
	)
	kernel=$(find "$RUN_DIR/kraft-tmp" -path '*/unikraft/bin/kernel' \
		-type f -print -quit)
	test -n "$kernel" || fail "Kraft did not unpack the base runtime kernel"
	cp "$kernel" "$BASE_KERNEL"
	kraft --no-prompt --no-emojis rm -f "$machine" >/dev/null 2>&1 || true
}

prepare_runtime

boot_once()
{
	fixture=$1
	expected=$2
	semantic=$3
	raw="$semantic.raw"
	rootfs="$semantic.rootfs"
	initrd="$semantic.cpio"
	mkdir "$rootfs"
	cp "$BINARY" "$rootfs/ld-kv"
	cp "$fixture" "$rootfs/fixture.in"
	(cd "$rootfs" && find . -print | cpio -o -H newc) >"$initrd" 2>/dev/null
	qemu-system-x86_64 \
		-accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed \
		-machine pc -m 64M -display none -serial stdio -monitor none \
		-no-reboot -parallel none -vga none \
		-kernel "$BASE_KERNEL" -initrd "$initrd" \
		-append 'random.seed=[ 0x1 0x2 0x3 0x4 0x5 0x6 0x7 0x8 ] vfs.fstab=[ "initrd0:/:extract:::" ] -- /ld-kv /fixture.in' \
		>"$raw" 2>&1 \
		|| fail "kraft/QEMU boot failed for $(basename "$fixture")"
	semantic_frames "$expected" "$raw" >"$semantic"
	test -s "$semantic" || fail "no semantic frames captured for $(basename "$fixture")"
}

for fixture in "$PRODUCT_DIR"/fixtures/*.in; do
	name=$(basename "$fixture" .in)
	expected="$PRODUCT_DIR/expected/$name.out"
	hash_record="$PRODUCT_DIR/expected/$name.sha256"
	test -f "$expected" || fail "missing $expected"
	test -f "$hash_record" || fail "missing $hash_record"
	wanted=$(sed -n '1p' "$hash_record")
	test "$(hash_file "$expected")" = "$wanted" || fail "$name expected blob/hash disagree"

	baseline=
	run=1
	while test "$run" -le 3; do
		semantic="$RUN_DIR/$name.$run.out"
		boot_once "$fixture" "$expected" "$semantic"
		actual=$(hash_file "$semantic")
		test "$actual" = "$wanted" || fail "$name boot $run: expected $wanted, got $actual"
		if test -n "$baseline"; then
			cmp -s "$baseline" "$semantic" || fail "$name boot $run differs byte-for-byte"
		else
			baseline=$semantic
		fi
		run=$((run + 1))
	done
	printf 'PASS %-20s %s (3 fresh boots) [unikraft-confined-transducer-experimental]\n' "$name" "$wanted"
done

# Negative control: a changed input must not accidentally validate against the
# committed basic transcript. This also boots through the same guest path.
negative="$RUN_DIR/negative.in"
sed 's/PUT b 2/PUT b changed/' "$PRODUCT_DIR/fixtures/basic.in" >"$negative"
negative_out="$RUN_DIR/negative.out"
boot_once "$negative" "$PRODUCT_DIR/expected/basic.out" "$negative_out"
test "$(hash_file "$negative_out")" != "$(cat "$PRODUCT_DIR/expected/basic.sha256")" \
	|| fail "negative control did not change semantic output"
printf 'PASS negative-control     altered fixture changed semantic hash\n'
