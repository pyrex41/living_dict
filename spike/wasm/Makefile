.PHONY: test build durable-gate clean
build:
	cargo component build --target wasm32-unknown-unknown --release --locked --offline -p kv-component -p order-component
	cargo build --release --locked --offline -p ld-wasm
test:
	cargo test --workspace --locked --offline
durable-gate: build
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	./target/release/ld-wasm run --workspace . --run-dir "$$tmp/kv" --claim-id kv --config machine.toml > "$$tmp/kv.json"; \
	./target/release/ld-wasm run --workspace . --run-dir "$$tmp/order" --claim-id order --config order.machine.toml > "$$tmp/order.json"; \
	grep -q '"passed":true' "$$tmp/kv.json"; grep -q '"replay_count":3' "$$tmp/kv.json"; \
	grep -q '"logical_committed":1' "$$tmp/order.json"; grep -q '"replayed":0' "$$tmp/order.json"; \
	cp "$$tmp/kv/oplog.jsonl" "$$tmp/tampered.jsonl"; printf x >> "$$tmp/tampered.jsonl"; \
	test "$$(sha256sum "$$tmp/kv/oplog.jsonl" | cut -d' ' -f1)" != "$$(sha256sum "$$tmp/tampered.jsonl" | cut -d' ' -f1)"; \
	echo 'durable-gate: KV replay/checkpoint/fork and order effect recovery PASS'
clean:
	cargo clean
