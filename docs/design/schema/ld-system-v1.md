# `ld-system/v1`

One typed, content-addressed description of a composed system. It is the
root of the refinement tree: component contracts, substrate requirements,
formal obligations, runtime claims, and (later) deployment all derive from
it or are checked against it. Loader and structural validation:
`beam/lib/ld_host/system_manifest.ex`. Judgments and obligations:
`beam/lib/ld_host/elaborate.ex` (`mix ld.elaborate --manifest FILE`).
Example: [`examples/orders/ld-system.json`](../../../examples/orders/ld-system.json).

The manifest's identity is the SHA-256 of its RFC 8785 canonical JSON
(`LdHost.SystemManifest.hash/1`). Every derived artifact carries that hash.

## Shape

```jsonc
{
  "schema": "ld-system/v1",
  "system": "orders",
  "components": {
    "<name>": {
      "contract": "order-api/v1",                 // component contract id
      "artifact": "sha256:<64 hex>",              // content address of the build
      "substrate": "wasm-durable-v1",             // a profile in LdHost.Substrates
      "ports": { "<port>": { "direction": "in" | "out", "type": "<message type>" } },
      "requires": { "<dimension>": "<value>", "fault_controls": ["crash"] }
    }
  },
  "externals": { "<name>": { "kind": "provider", ... } },   // things outside the system
  "channels": {
    "<name>": {
      "from": "<component>.<port>",              // must be an out port
      "to": "<component>.<port>",                // must be an in port of the same type
      "delivery": "at-most-once" | "at-least-once" | "exactly-once",
      "ordering": "none" | "per-key" | "total",
      "capacity": 16,
      "faults": ["drop", "duplicate", "delay", "reorder"]
    }
  },
  "effects": {
    "<name>": {
      "owner": "<component>",                    // exactly one owner
      "protocol": "durable-intent-commit" | "recorded" | "ambient",
      "identity": "host-derived" | "guest",
      "target": "<external>"                     // optional
    }
  },
  "invariants": [
    { "id": "<id>", "kind": "safety" | "liveness" | "forbidden-path" | "required-waypoint",
      "about": ["<component|channel|effect|external>", ...] }
  ],
  "failure_model": ["crash-before-effect", "crash-after-effect", "crash-after-commit",
                    "message-duplicate", "message-reorder", "message-drop", "message-delay",
                    "partition", "heal", "provider-timeout"]
  // "deployment" is reserved and must be absent in v1
}
```

## Substrate dimensions

`requires` is matched against the substrate's capability vector
(`LdHost.Substrates`). Each dimension is ordered weakest to strongest; a
requirement is met when the guarantee is at least as strong. Unknown
dimensions or values are unmet, never ignored.

| dimension | values (weak to strong) |
|---|---|
| `isolation` | none, process, container, microvm, wasm-component |
| `clock` | ambient, recorded, logical |
| `entropy` | ambient, ambient-seeded, seeded-replayable |
| `scheduler` | preemptive, cooperative, host-serialized |
| `filesystem` | ambient, mediated, read-only-image, none |
| `network` | ambient, recorded, mediated-messages, none |
| `external_effects` | ambient, recorded, durable-intent-commit |
| `snapshot` | none, component, whole-machine |
| `global_checkpoint` | unsupported, supported |
| `floating_point` | platform, canonical |
| `memory_growth` | platform, bounded, deterministic |
| `replay` | none, rerun-only, in-process, cross-process |
| `branching` | unsupported, supported |
| `build_reproducibility` | unpinned, pinned, attested |
| `fault_controls` | set; requirement must be a subset |

Registered profiles and their honest vectors:

- `wasm-durable-v1`: wasm-component, logical, seeded-replayable,
  host-serialized, none, none, durable-intent-commit, whole-machine,
  unsupported, canonical, bounded, cross-process, supported, [crash],
  attested. Claim-capable.
- `unikraft-confined-transducer-experimental`: microvm, ambient,
  ambient-seeded, cooperative, read-only-image, none, ambient, none,
  unsupported, platform, platform, rerun-only, unsupported, [], unpinned.
  Not claim-capable.

## Judgments (`ld.derivation/v1`)

Rules apply in a fixed order and every step is recorded, so two
elaborations of one manifest are byte-identical and a rejection lists every
unmet judgment.

| rule | judgment |
|---|---|
| `component-well-formed` | component names a registered substrate |
| `channel-endpoints` | both endpoints declared, out to in, equal port types |
| `effect-owner` | owner is a component; its substrate carries the protocol; host-derived identity needs `durable-intent-commit` |
| `substrate-satisfies` | every `requires` dimension met, one step per unmet dimension |
| `substrate-admissible` | the substrate may back runtime claims |
| `invariant-scope` | `about` names only declared things |
| `failure-model` | entries are in the vocabulary |

An accepted manifest yields obligations, each `tool:kind:subject`:

- `runtime:replay-stable:<component>`, `runtime:checkpoint-recovered:<component>`
- `tla:delivery-<delivery>:<channel>`
- `runtime:effects-exactly-once:<effect>` for durable effects
- `tla:invariant:<id>` / `tla:liveness:<id>`; `netkat:isolated:<a>-><b>` /
  `netkat:waypoint:...` for path invariants
- `exploration:<fault>:<system>`

All obligations start `unresolved`. Discharging them is Phases 3 to 5 of
[`DURABLE_SYSTEM_PLAN.md`](../DURABLE_SYSTEM_PLAN.md).
