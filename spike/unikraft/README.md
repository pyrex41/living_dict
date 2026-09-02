# Unikraft harness spike (Lua body)

Organs are **pure Lua transducers** wired by a **NetKAT fabric** and
sequenced by a transcription of `kernel.reduce`. No Python on this path.
Unikraft Kraftfiles are the intended packaging; they are not built here
(macOS, no `kraft`, Docker daemon down). See `docs/design/UNIKRAFT.md`.

```bash
orb start                            # Docker via OrbStack (Colima works too)
make -C spike/unikraft test          # luajit selftest.lua (no Nix required)
make -C spike/unikraft product-gate  # 3 QEMU boots per KV fixture + negative control
make -C spike/unikraft kraft-hello   # nix develop + kraft + qemu helloworld
nix develop                          # kraft 0.12.15, qemu, luajit (flake.nix)
```

| path | what |
|---|---|
| `lua/` | NetKAT, fabric, kernel, organs, sequencer |
| `model/fabric.netkat` | isolation policy |
| `model/Episode.tla` | TLA+ of reduce/reconcile |
| `model/component.shen` | Shen hop contracts |
| `kraft/` | intended Unikraft images (unbuilt) |
| `selftest.lua` | isolation, reject-does-not-write, replay |
| `product/` | deterministic in-memory KV product and QEMU gate |

Critic is `openresty/lua/forth.lua` `validate` (same contracts as Shen).
Store intern is `openresty/lua/host.lua` `sha256` / canonical JSON.
The guest does not observe a wall clock.
