REPO := $(abspath .)
RESTY := $(REPO)/openresty/bin/livingdict-resty
ENVELOPE_CONFIG_01 := $(REPO)/openresty/examples/config-01.envelope.json
# Ratatoskr was renamed Yggdrasil (repo may still sit at ../ratatoskr).
YGGDRASIL ?= $(shell command -v yggdrasil 2>/dev/null || echo $(HOME)/go/bin/yggdrasil)
BIFROST ?= $(shell command -v bifrost 2>/dev/null || echo $(HOME)/.local/bin/bifrost)
SHENSCRIPT ?= $(REPO)/../ShenScript/bin/shen.js
SHEN_CL ?= $(REPO)/../shen-cl/bin/sbcl/shen
# shen-cl's default 1GB heap OOMs on this shake; ShenScript is the stage-1 host.
ifneq ($(wildcard $(SHENSCRIPT)),)
YGGDRASIL_HOST ?= node $(SHENSCRIPT)
endif

.PHONY: eval-test eval-oracle harness-test openresty-test eval-resty-config-01 openresty-serve think-config-01 client-test livingdict client-web test browser-test browser-shake browser-serve compare compare-dry scudcheck pack-critic critic-suite

eval-test:
	cd eval && python3 -m unittest discover -s tests -v

eval-oracle:
	cd eval && python3 -m ldeval run --oracle --arm oracle --output runs/oracle

harness-test:
	cd harness && PYTHONPATH=src python3 -m unittest discover -s tests -v

openresty-test:
	luajit openresty/selftest.lua

eval-resty-config-01:
	cd eval && LIVINGDICT_ENVELOPE="$(ENVELOPE_CONFIG_01)" python3 -m ldeval run \
		--agent-command "$(RESTY)" \
		--arm forth-shen \
		--memory-mode cold \
		--tasks config-01 \
		--output "$(REPO)/runs/resty-config-01"

openresty-serve:
	mkdir -p openresty/logs openresty/var/run/think/dictionary/words apps/studio
	openresty -p "$(REPO)/openresty/" -c nginx.conf

think-config-01:
	openresty/scripts/think-config-01.sh

client-test:
	cd client && python3 -m unittest discover -s . -v

livingdict:
	PYTHONPATH=$(REPO)/harness/src python3 -m livingdict

compare-dry:
	python3 client/compare.py --dry-run

compare:
	@test -n "$(PROMPT)" || (echo 'usage: make compare PROMPT="..." [COMPARE_FLAGS=...]'; exit 2)
	python3 client/compare.py --prompt "$(PROMPT)" $(COMPARE_FLAGS)

client-web:
	cd client/web && npm install && npm run build

test: eval-test harness-test openresty-test critic-suite scudcheck

scudcheck:
	@if ! command -v go >/dev/null 2>&1; then echo "skip scudcheck: go not found"; exit 0; fi
	@if [ ! -f "$(REPO)/../scud/pkg/executor/rho_v1.go" ]; then echo "skip scudcheck: scud checkout not found"; exit 0; fi
	@cd "$(REPO)/tools/scudcheck" && go build -o scudcheck .
	@if "$(REPO)/tools/scudcheck/scudcheck" -run-id fixture-2 < "$(REPO)/harness/tests/fixtures/invalid_after_terminal.jsonl"; then \
		echo "scudcheck: expected invalid_after_terminal.jsonl to fail"; exit 1; \
	fi
	@echo "scudcheck: rejected invalid_after_terminal.jsonl"

browser-test:
	node browser/test/node-selftest.mjs

browser-shake:
	@if [ ! -x "$(YGGDRASIL)" ]; then echo "yggdrasil not found. go install github.com/pyrex41/yggdrasil@latest (or build ../ratatoskr)"; exit 1; fi
	mkdir -p browser/dist/critic openresty/dist/critic
	$(YGGDRASIL) build shen/critic/validate.shen browser/dist/critic --target js --web $(if $(YGGDRASIL_HOST),--host "$(YGGDRASIL_HOST)")
	$(YGGDRASIL) build shen/critic/validate.shen openresty/dist/critic --target lua $(if $(YGGDRASIL_HOST),--host "$(YGGDRASIL_HOST)")
	cp browser/dist/critic/app.js browser/dist/critic.js
	@grep -q 'needs-eval=false' browser/dist/critic/yggdrasil.manifest.txt
	@echo "shaken js -> browser/dist/critic/app.js"
	@echo "shaken lua -> openresty/dist/critic/app.lua"

# suite.shen is a mechanical pack: header + validate.shen + suite-tests.shen.
# Never edit it by hand; repack after touching either source.
pack-critic:
	@{ printf '\\\\ Living Dictionary critic fixture (bifrost script-mode).\n'; \
	   printf '\\\\ Self-contained: no load / eval / runtime tc. Marker: ALL PASS\n'; \
	   printf '\\\\ Packed by make pack-critic from validate.shen + suite-tests.shen.\n'; \
	   printf '\n'; \
	   cat shen/critic/validate.shen; \
	   printf '\n'; \
	   cat shen/critic/suite-tests.shen; } > shen/critic/suite.shen
	@echo "packed -> shen/critic/suite.shen"

# Run the packed critic suite on a local Shen host; ALL PASS or fail.
critic-suite: pack-critic
	@if [ -x "$(SHEN_CL)" ]; then \
	   "$(SHEN_CL)" eval -q -l shen/critic/suite.shen 2>&1 | tee /tmp/critic-suite.out | grep -q 'ALL PASS' \
	     || { tail -30 /tmp/critic-suite.out; echo "critic-suite: FAIL"; exit 1; }; \
	 elif [ -f "$(SHENSCRIPT)" ]; then \
	   node "$(SHENSCRIPT)" eval -q -l shen/critic/suite.shen 2>&1 | tee /tmp/critic-suite.out | grep -q 'ALL PASS' \
	     || { tail -30 /tmp/critic-suite.out; echo "critic-suite: FAIL"; exit 1; }; \
	 else echo "skip critic-suite: no Shen host (build ../shen-cl or ../ShenScript)"; exit 0; fi
	@echo "critic-suite: ALL PASS"

browser-serve:
	python3 -m http.server --directory browser
