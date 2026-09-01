# Bounded research OODA

The BEAM host has an opt-in `ooda=auto` mode. It replaces the legacy whole-workspace planner observation with a compact manifest and either a direct source pack or a bounded read-only investigation.

The investigator can only list workspace metadata, read line ranges, and perform literal text searches. It receives two tool rounds, eight calls, 16 KiB per result, and 64 KiB total evidence. It cannot write, execute commands or tests, use the network, change claims, or expand policy. Sensitive, host-internal, escaping, and symlinked paths are denied. Its cited JSON brief is validated against returned evidence before a separate planner sees it.

The envelope still passes through the ordinary non-LLM critic, capability host, and approved gates. A semantic failure permits one focused researched repair at the next reasoning-effort level; another failure halts. Transport retries do not consume that repair.

## Driving it

```bash
cd beam
mix ld.run --goal "..." --cwd /tmp/workspace --contract /path/claims.json --ooda auto
mix ld.demo --tasks parser-02,graph-08 --arms cold --serial --ooda auto
```

Release configuration uses `LD_OODA_MODE=auto`. Fixed comparison runs can use `--reasoning-effort high` or `LD_REASONING_EFFORT=high`; fixed effort and auto mode are mutually exclusive. The default remains legacy `off` until paired protected-verifier runs establish no correctness regression and a meaningful total-token improvement.

Run results and ledgers report the initial route, research calls and evidence bytes, unresolved questions, and repair use. All investigator and planner calls count toward the same token and model-call totals.
