# LLM flight recorder

The BEAM planner normally talks directly to xAI. For latency diagnosis it can
instead use a metadata-first OpenAI-compatible forwarding proxy. The proxy
forwards `Authorization` but never logs it. By default it records only hashes,
byte counts, model parameters, response usage, time to response headers, and
total duration. Exact prompts and responses require an explicit
`--capture-bodies` opt-in.

Planner receipts retain visible completion tokens separately from hidden
reasoning tokens and use the provider's `total_tokens` for new campaign cost
comparisons. Historical rows without `total_tokens` retain the previous
input-plus-output fallback.

Run the proxy under OrbStack/Docker:

```bash
mkdir -p /tmp/livingdict-flight-recorder
LIVINGDICT_FLIGHT_LOG_DIR=/tmp/livingdict-flight-recorder \
  docker compose -f compose.llm-flight-recorder.yml up --build -d
```

Route one isolated task through it:

```bash
cd beam
LIVINGDICT_PLANNER_ENDPOINT=http://127.0.0.1:8765/v1/chat/completions \
  mix ld.demo --tasks parser-01 --arms cold --serial --max-episodes 6 \
  --out /tmp/livingdict-parser-flight
```

Inspect `/tmp/livingdict-flight-recorder/llm.jsonl`, then stop the proxy:

```bash
docker compose -f compose.llm-flight-recorder.yml down
```

The proxy container is read-only, drops Linux capabilities, has
`no-new-privileges`, and receives no credential volume. This isolates the
recorder, not the BEAM host. A stronger experiment can put the host in a
second container and allow egress only to the recorder; the application-level
trace remains the same.
