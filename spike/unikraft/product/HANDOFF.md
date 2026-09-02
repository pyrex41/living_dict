# Codex handoff — deterministic KV product gate

## Resolved

The blocker described below was resolved in this worktree. KraftKit 0.12.15
correctly resolves and unpacks the qemu/x86_64 `unikraft.org/base` runtime but
daemonizes QEMU and disconnects fixture stdin. `gate.sh` now asks Kraft for
that exact runtime with `--no-start`, packages each fixture into an initrd,
and boots the resolved kernel in foreground QEMU TCG with `/ld-kv
/fixture.in`. `make -C spike/unikraft product-gate` and `make -C
spike/unikraft test` are green.

Resume this, do not start a new architecture. Worktree:

`/Users/reuben/projects/living_dict-unikraft-spike`
branch `spike/unikraft-harness`

## Vision (do not regress)

Living Dictionary’s **control plane is already good enough**. Do not harden `kernel.py` / `lua/seq.lua` / NetKAT organs for determinism.

The product **Living Dictionary writes** must be a deterministic machine. `RUN-GATES` should boot that machine on committed fixtures and hash semantic output. Unikraft (or WASM later) is the **product runtime**, not a rewrite of the harness.

Six-word ABI frozen. No new Forth words. Never edit `eval/`. No Python on this path.

## Already done

Under `spike/unikraft/product/`:

- `main.c` — in-memory KV: `PUT`/`GET`/`DELETE`/`DUMP`/`HALT`. Successful GET is `VALUE <key> <value>` (spec omitted that frame). DUMP is byte-sorted `KEY …` then `OK`.
- Hand-authored `fixtures/*.in` and `expected/*.out` + `expected/*.sha256` (do not regenerate expected from a run).
- `machine.toml`, native `Kraftfile` + `Makefile.uk`, `loader/Kraftfile` (`runtime: unikraft.org/base:latest`).
- `gate.sh` — musl static-PIE cross-build, 3 boots/fixture, strip to first expected line through `HALT`, negative control, Kraftfile grep for ukrandom/lwip/clock/scheduler/9p.
- `make -C spike/unikraft product-gate` → `nix develop --command ./product/gate.sh`
- Flake includes `pkgs.pkgsCross.musl64.stdenv.cc` (`x86_64-unknown-linux-musl-gcc`).
- `make -C spike/unikraft test` (Lua organ selftest) is green.

## Blocked (this is the job)

1. **Native Unikraft image** — `kraft build` of `product/Kraftfile` dies: no `x86_64-elf-gcc` on this Mac.
2. **ELF-loader boot** — `kraft run --plat qemu --arch x86_64 -W --rm $BINARY` with stdin fixture **panics KraftKit 0.12.15**:

```
using compatible context candidate=linuxu
pulling unikraft.org/base
runtime error: invalid memory address or nil pointer dereference
kraftkit.sh/internal/cli/kraft/run.(*RunOptions).Run ... run.go:409
```

Catalog helloworld **does** work (no stdin, not linuxu):

```
orb start   # Docker context orbstack
cd spike/unikraft
nix develop --command kraft --no-prompt --no-emojis --log-type basic \
  run --plat qemu --arch x86_64 -W --rm --memory 64Mi \
  unikraft.org/helloworld:latest
```

The gate currently **fails honestly** (`no semantic frames captured`). Do not make it pass by hashing host-side `main` execution.

## Your task

Get **one** path that actually boots the KV machine under kraft/QEMU TCG, then make `make -C spike/unikraft product-gate` green:

- 3 fixtures × 3 boots, hashes match committed expected
- negative control still fails the basic hash
- banners/timing never in the hashed blob
- existing Lua selftest still green

Preferred order:

1. Unstick `kraft run BINARY` / linuxu / `unikraft.org/base` (stdin, `-W`, qemu/x86_64). Workaround kraft bugs if needed (loader Kraftfile + rootfs, `--rootfs`, no stdin / initrd fixture, qemu argv, newer kraft from NUR only if flake-pinned).
2. Else native guest: add a **Nix-packaged** `x86_64-elf-gcc` (or kraft’s documented toolchain) to `spike/unikraft/flake.nix` and `kraft build` `product/Kraftfile` with **no** ukrandom/lwip/scheduler/9p/clock. Wire `gate.sh` to that kernel.
3. Do not declare victory with a macOS-native binary test of `main.c`.

Host: macOS arm64. OrbStack provides Docker. Kraft 0.12.15 comes from `github:unikraft/nur` via the flake.

## Product protocol (keep)

Line-oriented UTF-8 stdin. Empty lines ignored.

| in | out |
|---|---|
| `PUT k v` | `OK` |
| `GET k` hit | `VALUE k v` |
| `GET k` miss | `MISSING k` |
| `DELETE k` | `OK` |
| `DUMP` | `KEY k v` lines (strcmp order) then `OK` |
| unknown | `ERR unknown` |
| `HALT` | `HALT` then exit 0 |

No clock, RNG, net, host FS, threads. State = guest RAM only.

## Out of scope

Harness organs, NetKAT fabric, TLA+ of `kernel.reduce`, Python livingdict, eval suite, adding Forth words, claiming Unikraft makes pytest deterministic.
