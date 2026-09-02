LUA ?= luajit
NIX ?= nix

.PHONY: test product-gate shell kraft-hello kraft-version

test:
	$(LUA) selftest.lua

product-gate:
	nix develop --command ./product/gate.sh

# OrbStack (or Colima) must be running: `orb start` then docker context use orbstack
shell:
	$(NIX) develop --command bash -lc 'kraft version; luajit -v; qemu-system-x86_64 --version | head -1'

kraft-version:
	$(NIX) develop --command kraft version

# Prebuilt catalog image via kraft + qemu (not a custom organ build)
kraft-hello:
	$(NIX) develop --command kraft --no-prompt --no-emojis --log-type basic \
		run --plat qemu --arch x86_64 -W --rm --memory 64Mi \
		unikraft.org/helloworld:latest
