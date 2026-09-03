.PHONY: test build durable-gate kill-matrix clean
LD_WASM := ./target/release/ld-wasm
GUESTS := -p kv-component -p order-component -p bad-snapshot-component
KILL_POINTS := before-intent after-intent during-provider after-provider-before-commit after-commit-before-deliver after-transition-before-checkpoint
# Evidence from the kill matrix is kept here so the BEAM verifier can be run
# over it afterwards (`make beam-durable-e2e` at the repo root).
MATRIX_DIR := .livingdict-run/kill-matrix

build:
	cargo component build --offline --target wasm32-unknown-unknown --release --locked $(GUESTS)
	cargo build --offline --release --locked -p ld-wasm

test:
	cargo test --offline --workspace --locked

# Positive runs, negative fixture, oplog tamper check, then the kill matrix.
durable-gate: build
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	$(LD_WASM) run --workspace . --run-dir "$$tmp/kv" --config machine.toml > "$$tmp/kv.json"; \
	$(LD_WASM) run --workspace . --run-dir "$$tmp/order" --config order.machine.toml > "$$tmp/order.json"; \
	grep -q '"passed":true' "$$tmp/kv.json"; grep -q '"replay_count":3' "$$tmp/kv.json"; \
	grep -q '"passed":true' "$$tmp/order.json"; \
	grep -q '"logical_committed":4' "$$tmp/order.json"; grep -q '"executed":4' "$$tmp/order.json"; \
	grep -q 'effects-exactly-once' "$$tmp/order.json"; grep -q 'guest-hash-discriminates' "$$tmp/order.json"; \
	if grep -q 'effects-exactly-once' "$$tmp/kv.json"; then echo 'kv has no effects; exactly-once must not be granted vacuously'; exit 1; fi; \
	test "$$(grep -c '"status":"executed"' "$$tmp/order/provider-calls.jsonl")" = 4; \
	$(LD_WASM) run --workspace . --run-dir "$$tmp/bad" --config bad-snapshot.machine.toml > "$$tmp/bad.json" || true; \
	grep -q '"passed":false' "$$tmp/bad.json" || { echo 'bad-snapshot guest must fail'; exit 1; }; \
	grep -q 'snapshot round trip failed' "$$tmp/bad.json"; \
	cp "$$tmp/kv/oplog.jsonl" "$$tmp/tampered.jsonl"; printf x >> "$$tmp/tampered.jsonl"; \
	test "$$(sha256sum "$$tmp/kv/oplog.jsonl" | cut -d' ' -f1)" != "$$(sha256sum "$$tmp/tampered.jsonl" | cut -d' ' -f1)"; \
	echo 'durable-gate: KV replay/checkpoint/fork, order effects, bad-snapshot rejection PASS'; \
	$(MAKE) --no-print-directory kill-matrix BASELINE="$$(grep -o '"final_state_hash":"[0-9a-f]*"' "$$tmp/order.json" | head -1)"

# Kill the runner at every declared boundary in three ways, resume in a fresh
# process, and require one provider execution per effect key and the same
# final state as the unkilled run:
#   abort            annotated abort (fault-injection entry, provider survives)
#   sigkill          SIGKILL to the executor, nothing journaled, provider survives
#   sigkill-provider SIGKILL to executor and provider; provider rebuilds from its log
kill-matrix:
	@set -eu; test -n "$(BASELINE)"; rm -rf "$(MATRIX_DIR)"; mkdir -p "$(MATRIX_DIR)"; \
	for mode in abort sigkill sigkill-provider; do \
	for point in $(KILL_POINTS); do \
	  dir="$(MATRIX_DIR)/$$mode-$$point"; \
	  case "$$mode" in \
	    abort) flags="--kill-mode abort" ;; \
	    sigkill) flags="--kill-mode sigkill" ;; \
	    sigkill-provider) flags="--kill-mode sigkill --kill-provider" ;; \
	  esac; \
	  if $(LD_WASM) run --workspace . --run-dir "$$dir" --config order.machine.toml --kill-at "$$point" $$flags > "$$dir.aborted.json" 2>/dev/null; then \
	    echo "kill-matrix: $$mode $$point did not die"; exit 1; fi; \
	  if [ "$$mode" = abort ]; then grep -q '"kind":"fault-injection"' "$$dir/oplog.jsonl"; \
	  else if grep -q '"kind":"fault-injection"' "$$dir/oplog.jsonl"; then echo "kill-matrix: $$mode wrote a marker"; exit 1; fi; fi; \
	  $(LD_WASM) resume --workspace . --run-dir "$$dir" --config order.machine.toml > "$$dir/receipt.json"; \
	  grep -q '"passed":true' "$$dir/receipt.json"; \
	  grep -q 'crash-recovered' "$$dir/receipt.json"; grep -q 'effects-exactly-once' "$$dir/receipt.json"; \
	  grep -q '"kind":"resume"' "$$dir/oplog.jsonl"; \
	  test "$$(grep -c '"status":"executed"' "$$dir/provider-calls.jsonl")" = 4; \
	  if [ "$$mode" = sigkill-provider ]; then grep -q '"kind":"restart"' "$$dir/provider-calls.jsonl" || { echo "kill-matrix: provider was not restarted from its log"; exit 1; }; fi; \
	  grep -q '$(BASELINE)' "$$dir/receipt.json" || { echo "kill-matrix: $$mode $$point final state differs from unkilled run"; exit 1; }; \
	  rm -f "$$dir.aborted.json"; \
	  printf 'kill-matrix: %-17s %-36s resumed, 4 executions, state identical PASS\n' "$$mode" "$$point"; \
	done; done; \
	echo "kill-matrix: evidence for BEAM verification under $(MATRIX_DIR)"

clean:
	cargo clean
