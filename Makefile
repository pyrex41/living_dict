REPO := $(abspath .)
RESTY := $(REPO)/openresty/bin/livingdict-resty
ENVELOPE_CONFIG_01 := $(REPO)/openresty/examples/config-01.envelope.json
RATATOSKR ?= $(shell command -v ratatoskr 2>/dev/null || echo $(HOME)/go/bin/ratatoskr)
BIFROST ?= $(shell command -v bifrost 2>/dev/null || echo $(HOME)/.local/bin/bifrost)
SHENSCRIPT ?= $(REPO)/../ShenScript/bin/shen.js
# shen-cl's default 1GB heap OOMs on this shake; ShenScript is the stage-1 host.
ifneq ($(wildcard $(SHENSCRIPT)),)
RATATOSKR_HOST ?= node $(SHENSCRIPT)
endif

.PHONY: eval-test eval-oracle harness-test openresty-test eval-resty-config-01 openresty-serve think-config-01 client-test livingdict client-web test browser-test browser-shake browser-serve compare compare-dry scudcheck

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

test: eval-test harness-test openresty-test scudcheck

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
	@if [ ! -x "$(RATATOSKR)" ]; then echo "ratatoskr not found. go install github.com/pyrex41/ratatoskr@latest"; exit 1; fi
	mkdir -p browser/dist/critic openresty/dist/critic
	$(RATATOSKR) build shen/critic/validate.shen browser/dist/critic --target js --web $(if $(RATATOSKR_HOST),--host "$(RATATOSKR_HOST)")
	$(RATATOSKR) build shen/critic/validate.shen openresty/dist/critic --target lua $(if $(RATATOSKR_HOST),--host "$(RATATOSKR_HOST)")
	cp browser/dist/critic/app.js browser/dist/critic.js
	@grep -q 'needs-eval=false' browser/dist/critic/ratatoskr.manifest.txt
	@echo "shaken js -> browser/dist/critic/app.js"
	@echo "shaken lua -> openresty/dist/critic/app.lua"

browser-serve:
	python3 -m http.server --directory browser
