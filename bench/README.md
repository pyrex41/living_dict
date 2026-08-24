# External benchmark adapters

These adapters keep benchmark-native verifiers authoritative. Living
Dictionary's claims, when present, are telemetry and must not replace Harbor
or SWE-bench scoring.

## Terminal-Bench through Harbor

Run a one-task smoke test locally (Docker is required):

```bash
PYTHONPATH=. harbor run \
  --dataset terminal-bench@2.1 \
  --agent bench.harbor_livingdict:LivingDictionary \
  --model xai/grok-4.6 \
  --n-tasks 1 --n-concurrent 1 \
  --jobs-dir bench/results/terminal-bench
```

Pass model credentials with Harbor's `--agent-env`, for example
`--agent-env XAI_API_KEY=...`. Pin `--agent-kwarg repo_ref=<commit>` when
publishing a result. Use `--include-task-name` to reproduce a task exactly.

## SWE-bench predictions and grading

Generate a prediction for one or more instances:

```bash
bench/run_swebench_livingdict.sh \
  --dataset SWE-bench/SWE-bench_Verified \
  --limit 1 --output bench/results/swebench/predictions.jsonl
```

Then use the official evaluator:

```bash
swebench eval verified \
  --predictions bench/results/swebench/predictions.jsonl \
  --run-id livingdict-smoke --instance <instance-id> --workers 1
```

The generator records the Living Dictionary exit/stderr alongside the
standard `instance_id`, `model_name_or_path`, and `model_patch` fields. A
failed or timed-out agent produces an empty patch and remains a benchmark
failure; it is never converted into a pass by a local claim.
