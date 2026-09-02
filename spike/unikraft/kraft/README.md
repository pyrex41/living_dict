# Intended Unikraft packaging (unbuilt)

These Kraftfiles are the OS budget for each organ. The catalog helloworld
image **does** run here via the Nix flake + OrbStack + QEMU TCG:

```bash
orb start
nix develop   # from spike/unikraft
make kraft-hello
```

Custom organ images (critic/host/store) are still unbuilt. Use the flake
for `kraft`, not a global install.

```
kraft build --target qemu-x86_64
kraft run --target qemu-x86_64
```

Rules every image must keep:

- no `lwip`, no `ukrandom`, no 9p
- cooperative scheduler or none (run-to-completion)
- I/O is virtio-console frames of the Message ABI
- the guest does not read a wall clock
- guest language is Lua (lib-lua) or C; never Python
