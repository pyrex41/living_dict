# Shen in this harness

The chat dumps never named **shen-go**. They named a dual-end pair by the same
author (pyrex41):

| Port | Role in the dumps |
|---|---|
| **shen-lua** | Server mind. Certified kernel, OpenResty examples, ~70ms boot. |
| **ShenScript** | Browser mind. Same `.shen` sources, JS interop, ~110KB gzip. |

`tiancaiamao/shen-go` and `pyrex41/shen-go` exist in the Shen ecosystem. They
were not part of this design. Do not take a Go kernel unless we later want a
single static binary and are willing to give up the dual-end `.shen` story.

## What runs today

`harness/adapters/forth_shen.py` uses `livingdict.preflight.validate` — stack,
effects, artifact keys, write globs. No Shen kernel on that path.

The OpenResty host loads **shen-lua** once per worker and runs named `validate`
in [`openresty/shen/preflight.shen`](../../openresty/shen/preflight.shen),
which calls the typed core in
[`openresty/shen/contracts.shen`](../../openresty/shen/contracts.shen).
Same `Accept | Reject` interface. Shen does not replace Forth.

`contracts.shen` here is the portable spec. Keep it aligned with
`openresty/shen/contracts.shen`. ShenScript can load the same ideas in the
browser later. Not a third dialect.

See [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md).

## What Shen is not

Shen does not emit patches. Shen does not call the model. Shen does not replace
Forth. The model writes a Forth envelope; Shen (or this preflight) only says
whether that program is allowed to run.
