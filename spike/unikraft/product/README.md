# KV product on Unikraft (`unikraft-confined-transducer-experimental`)

> **Profile status:** experimental. This gate demonstrates a confined C
> transducer behaving consistently across fresh QEMU boots. It is not a claim
> backend: the base runtime is pulled by tag rather than digest, the CPU model
> exposes RDRAND/RDSEED, there is no snapshot, no effect journal, and no
> verifier independent of the boot runner. Its honest capability vector is
> registered in `beam/lib/ld_host/substrates.ex`; the plan to graduate it is
> Phase 6 of `docs/design/DURABLE_SYSTEM_PLAN.md`.

This is a deliberately small Living Dictionary product: a C command machine
whose only state is a byte-sorted in-memory KV table. The product does not
contain or replace any harness control-plane organ.

Run the gate from the repository root:

```sh
make -C spike/unikraft product-gate
```

The gate cross-compiles `main.c` to an x86_64 Linux/musl static PIE. Kraft
resolves and unpacks the `unikraft.org/base` QEMU runtime; the gate then uses
Kraft's generated foreground QEMU shape to boot that kernel under TCG. Each
fixture is copied into the initrd and passed to `/ld-kv /fixture.in`, because
KraftKit 0.12.15 daemonizes QEMU and does not connect its serial stream to the
Linux process's standard input. The normal no-argument interface remains
line-oriented standard input.

The gate extracts only output from the first expected response through
`HALT`, and checks that semantic byte blob against its committed SHA-256.
Every fixture gets three fresh boots. A final negative control mutates an
input and requires the semantic hash to change. Boot banners, VM names, and
timings remain outside the extracted blob.

The native Unikraft `Kraftfile` and `Makefile.uk` are retained as the preferred
packaging. On this macOS arm64 host, its build reaches Unikraft's build system
but stops because `x86_64-elf-gcc` is unavailable. The gate therefore uses the
documented Linux-binary/ELF-loader fallback. `loader/Kraftfile` records the
explicit base-runtime packaging used to make Kraft resolve the guest kernel.

The spec did not name the successful `GET` frame; this experiment defines it
as `VALUE <key> <value>`. Missing keys retain the specified `MISSING` frame.
