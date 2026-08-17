# Module pipeline integration

`task_graph.json` describes three independent module nodes followed by a shared registry node and verification.
Add `NAME` and `describe()` to every module without changing its `apply()` behavior. Update `pipeline/registry.py`
so `STEPS` follows this exact dependency order: ingest, scale, offset. Add `describe_pipeline()` returning those names.

Independent module work may run in parallel, but the registry update must follow it. Do not modify the graph or tests.
Run `python -m unittest discover -s tests`. Only `pipeline/*.py` may change.
