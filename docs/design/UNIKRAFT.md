# Unikraft components for the harness — spike verdict

> **Status (2026-09-02):** the "what to port" order below is superseded by
> [`DURABLE_SYSTEM_PLAN.md`](DURABLE_SYSTEM_PLAN.md). Wasm is the reference
> semantics; the product gate under `spike/unikraft/product/` is to be
> renamed `unikraft-confined-transducer-experimental` and returns as a
> claim backend only in Phase 6. The Lua simulator is a model of the BEAM
> host, not a second implementation (see finding 10 in the plan).

**Branch:** `spike/unikraft-harness`
**Worktree:** `../living_dict-unikraft-spike` (this tree)
**Runnable evidence:** `make -C spike/unikraft test` (Lua/luajit; no Python)

## Verdict

**Workable as a confinement and composition layer. Not workable as the source of determinism.**

Unikraft is a library OS: you pick micro-libraries (`ukalloc`, `ukschedcoop`, `nolibc`, `vfscore`, `lwip`, …), statically link them with an application, and get a single-address-space VM. That is a good match for Living Dictionary *organs* (critic, Forth/host, store) if each organ is a **pure transducer** with explicit ports.

It is a bad match if the hope is “wrap the current Python CLI in unikernels and the episode becomes totally deterministic.” Unikraft still has clocks, optional `ukrandom`/`RDRAND`, lwIP timers and TCP ISNs, virtio interrupt timing, and a POSIX compatibility layer that reintroduces Linux-shaped nondeterminism. `STORE.md` already has the right rule: runtime may race; **replay reads the ledger**.

The three modeling languages split cleanly:

| Language | Owns | Already in-repo? |
|---|---|---|
| **Shen** | critic: stack/effects/globs, Accept \| Reject | yes (`shen/critic`, `preflight.py`) |
| **TLA+** | episode kernel: `reduce` / `reconcile`, wave barriers, claim discharge | `spike/unikraft/lua/kernel.lua` is the reducer on this path; TLA is a spec of that |
| **NetKAT** | fabric: who may send which packet kinds to whom | new; this is the missing piece |

Unikraft is the *packaging* of transducers. NetKAT is the *wiring*. The ledger is the *time*.

## What “always build using Unikraft components” can mean

Three readings. Only the first two are worth doing.

### 1. Organs as unikernels (recommended reading)

Each hot-path organ is its own image, built from a **minimal** micro-lib set:

```
ld-critic.ok     Shen/Lua critic     nolibc + console, no lwip, no ukrandom
ld-host.ok       Forth + capabilities  nolibc + ramfs, run-to-completion
ld-store.ok      blob/tree intern     nolibc + ramfs
ld-seq.ok        sequencer            the only process that may multiplex
```

The Lua sequencer (`spike/unikraft/lua/seq.lua`) is the orchestrator: start organs, feed framed messages, append whatever comes back to the kernel ledger. A kraft CLI can replace in-process calls with virtio-console later. There is no Python on this path.

Kraft’s actual value here is Kconfig composition, not “unikernels are deterministic.” You can refuse `lwip`, refuse `ukrandom`, pick `ukschedcoop` (or no scheduler), pick `ramfs` over 9p. That is a smaller TCB than “Python on Linux with a thread pool.”

### 2. Micro-libs as the host’s OS budget (same idea, one image)

One unikernel containing critic + Forth + store, still no POSIX, still no network stack. Cheaper to operate. Isolation between organs is then a software bus inside one address space — which is what the spike simulator is. NetKAT still describes the bus; Unikraft no longer enforces it at a VM boundary.

### 3. Lift the current Python body onto `lib-python3` (reject)

Python-on-Unikraft needs musl, pthreads, lwIP, a rootfs with the stdlib, and a long syscall shim. You reimport CPython hash seed, GC, and import-path accidents, plus Unikraft’s own clocks. The TCB gets larger, not smaller. The OpenResty/Lua body is a better unikernel guest than `harness/src/livingdict`.

## Determinism: what Unikraft does and does not give you

Unikraft EuroSys’21: scheduling is **optional**; a run-to-completion guest has no in-guest preemption. `ukschedcoop` is cooperative round-robin and still samples `ukplat_monotonic_clock()` to wake sleepers. `libukrandom` exists to serve `getrandom` from `RDRAND`/`RDSEED`. lwIP in threaded mode has a `tcpip_thread` and mailbox races.

So:

- **Single-threaded, no scheduler, no `ukrandom`, no lwIP, no wall clock, all I/O is a message on a port** → the guest *can* be a deterministic transducer.
- **Default catalog app (Python/NGINX/Redis + musl + lwIP + qemu rtc)** → not deterministic, just small.

Even a pure guest is scheduled by QEMU/Firecracker/KVM. Interrupt timing will differ across runs. That is fine **if the guest does not observe it**. The moment `RUN-TESTS` shells out to pytest, or the host reads `time.time()`, determinism is gone regardless of unikernel.

Product tests are the hard remaining source of nondeterminism. Unikraft does not hermeticize `RUN-TESTS`. A hermetic gate runner (fixed env, no network, content-addressed inputs, recorded stdout) is a separate project. The spike’s gates organ hashes the in-memory tree; that is the *shape* of a deterministic gate, not a replacement for pytest.

This is the same split `STORE.md` Layer B already made for waves: `take` may race; the ledger records the schedule; replay is the recorded schedule.

## Mapping onto the existing architecture

```
planner (model, outside the TCB)
    │  packet kind=plan
    ▼
sequencer  ── NetKAT fabric ──► critic (Shen)
    │ verdict
    ├─ reject  → events.jsonl, next episode
    └─ accept  → host (Forth + capabilities)
                      │ intern
                      ▼
                    store (Layer A blobs/trees)
                      │
                      ▼
                    gates (hermetic, or recorded)
```

Forbidden edges (NetKAT isolation, proven in `spike/unikraft/tests/test_fabric.py`):

- planner ↛ store
- planner ↛ host
- critic ↛ store
- critic ↛ host / workspace

The critic still never writes files, never calls a model, never executes the plan. The host still never runs a word the critic rejected. Those are already code invariants; NetKAT makes them *topology* invariants.

`kernel.reduce` stays the only state machine. Components emit **events**; they do not own `State`. That keeps TLA+ a spec of one reducer, not of four ad-hoc machines.

## Why NetKAT, TLA+, Shen — not one of them for everything

- **Shen** is already the policy language. Stack contracts and `write-ok?` are not packet forwarding. Do not rewrite the critic in TLA+.
- **TLA+** is for the episode loop and wave barriers (`pending_execute`, Accept/Reject, `claims_discharged`, cap). `kernel.py` is small enough that the TLA in `spike/unikraft/model/Episode.tla` is a transcription, not a redesign.
- **NetKAT** is Kleene algebra with tests over packet fields. Isolation (“does any packet of kind `intern` starting at `planner` reach `store`?”) is program equivalence against `drop`. That is the question Unikraft *wiring* must answer, and it is not a TLA+ question.

The three specs compose: Shen rejects a bad program; TLA+ says the kernel will not apply artifacts on reject; NetKAT says a critic packet cannot become a store intern even if a bug emits one.

## Platform reality (this machine)

- Host is macOS arm64. Unikraft guests run under QEMU TCG (`-W`).
- Env is a Nix flake (`spike/unikraft/flake.nix`): `kraft` 0.12.15, qemu, luajit.
- Docker is OrbStack (`orb start`; context `orbstack`). Colima is an alternative.
- Catalog `unikraft.org/helloworld:latest` **runs**. Custom organ `.ok` images are still unbuilt.

## What to port, in order, if this graduates

1. Freeze the transducer ABI (`Message` in `spike/unikraft/ld_uk/abi.py`). Do not add Forth words.
2. Keep `kernel.py` as the sequencer’s reducer. Do not duplicate it in the guest.
3. Port the **critic** first (Lua/Shen already boots under OpenResty; a console-framed `validate` unikernel is the smallest real image).
4. Port **store intern** second (pure hashing + ramfs; no POSIX).
5. Port **Forth host** third, in C or Lua, not CPython.
6. Leave the planner on the Linux/macOS side forever. The model is not a unikernel.
7. Do not put `RUN-TESTS` inside Unikraft until gates are hermetic on the host.

## Exit test for a real landing (not this spike)

- Byte-identical `tree_after` for canned fizzbuzz on the in-process simulator vs today’s Python host.
- NetKAT isolation queries stay green as code, not as comments.
- One organ (critic) actually boots under QEMU on Linux CI and answers the same `validate` vector as `preflight.py`.
- `make test` on main still green; eval ABI frozen.

Until that last image exists, Unikraft is an OS budget and a packaging story. Determinism remains the ledger plus pure transducers. The spike demonstrates that story without pretending QEMU is a time machine.
