.PHONY: test build durable-gate kill-matrix clean
LD_WASM := ./target/release/ld-wasm
GUESTS := -p kv-component -p order-component -p bad-snapshot-component
KILL_POINTS := before-intent after-intent during-provider after-provider-before-commit after-commit-before-deliver after-transition-before-checkpoint

build:
	cargo component build --target wasm32-unknown-unknown --release --locked $(GUESTS)
	cargo build --release --locked -p ld-wasm

test:
	cargo test --workspace --locked

# Positive runs, negative fixture, oplog tamper check, then the kill matrix.
durable-gate: build
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	$(LD_WASM) run --workspace . --run-dir "$$tmp/kv" --config machine.toml > "$$tmp/kv.json"; \
	$(LD_WASM) run --workspace . --run-dir "$$tmp/order" --config order.machine.toml > "$$tmp/order.json"; \
	grep -q '"passed":true' "$$tmp/kv.json"; grep -q '"replay_count":3' "$$tmp/kv.json"; \
	grep -q '"passed":true' "$$tmp/order.json"; \
	grep -q '"logical_committed":4' "$$tmp/order.json"; grep -q '"executed":4' "$$tmp/order.json"; \
	grep -q 'effects-exactly-once' "$$tmp/order.json"; grep -q 'guest-hash-discriminates' "$$tmp/order.json"; \
	test "$$(grep -c '"status":"executed"' "$$tmp/order/provider-calls.jsonl")" = 4; \
	$(LD_WASM) run --workspace . --run-dir "$$tmp/bad" --config bad-snapshot.machine.toml > "$$tmp/bad.json" || true; \
	grep -q '"passed":false' "$$tmp/bad.json" || { echo 'bad-snapshot guest must fail'; exit 1; }; \
	grep -q 'snapshot round trip failed' "$$tmp/bad.json"; \
	cp "$$tmp/kv/oplog.jsonl" "$$tmp/tampered.jsonl"; printf x >> "$$tmp/tampered.jsonl"; \
	test "$$(sha256sum "$$tmp/kv/oplog.jsonl" | cut -d' ' -f1)" != "$$(sha256sum "$$tmp/tampered.jsonl" | cut -d' ' -f1)"; \
	echo 'durable-gate: KV replay/checkpoint/fork, order effects, bad-snapshot rejection PASS'; \
	$(MAKE) --no-print-directory kill-matrix TMP="$$tmp" BASELINE="$$(grep -o '"final_state_hash":"[0-9a-f]*"' "$$tmp/order.json" | head -1)"

# Kill the runner at every declared boundary, resume in a fresh process, and
# require: one provider execution per effect key, the same final state as the
# unkilled run, and BEAM-checkable evidence.
kill-matrix:
	@set -eu; test -n "$(TMP)"; test -n "$(BASELINE)"; \
	for point in $(KILL_POINTS); do \
	  dir="$(TMP)/kill-$$point"; \
	  if $(LD_WASM) run --workspace . --run-dir "$$dir" --config order.machine.toml --kill-at "$$point" > "$$dir.aborted.json" 2>/dev/null; then \
	    echo "kill-matrix: $$point did not abort"; exit 1; fi; \
	  grep -q '"kind":"fault-injection"' "$$dir/oplog.jsonl"; \
	  $(LD_WASM) resume --workspace . --run-dir "$$dir" --config order.machine.toml > "$$dir.json"; \
	  grep -q '"passed":true' "$$dir.json"; \
	  grep -q 'crash-recovered' "$$dir.json"; grep -q 'effects-exactly-once' "$$dir.json"; \
	  grep -q '"kind":"resume"' "$$dir/oplog.jsonl"; \
	  test "$$(grep -c '"status":"executed"' "$$dir/provider-calls.jsonl")" = 4; \
	  grep -q '$(BASELINE)' "$$dir.json" || { echo "kill-matrix: $$point final state differs from unkilled run"; exit 1; }; \
	  printf 'kill-matrix: %-36s resumed, 4 executions, state identical PASS\n' "$$point"; \
	done

clean:
	cargo clean
