from __future__ import annotations

import json
import random
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Any, Callable


def load_results(path: Path) -> list[dict[str, Any]]:
    if path.is_file():
        candidates = [path]
    else:
        candidates = list(path.rglob("result.json"))
    values = []
    for candidate in candidates:
        try:
            values.append(json.loads(candidate.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    return values


def _median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def aggregate(results: list[dict[str, Any]]) -> dict[str, Any]:
    by_family: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for result in results:
        by_family[result["family"]].append(result)

    def metrics(items: list[dict[str, Any]]) -> dict[str, Any]:
        telemetry = [item.get("telemetry", {}) for item in items]
        return {
            "n": len(items),
            "success_rate": sum(bool(item.get("success")) for item in items) / len(items) if items else 0.0,
            "median_elapsed_seconds": _median([float(item.get("elapsed_seconds", 0)) for item in items]),
            "median_model_calls": _median([float(t.get("model_calls", 0)) for t in telemetry]),
            "median_total_tokens": _median([float(t.get("input_tokens", 0)) + float(t.get("output_tokens", 0)) for t in telemetry]),
            "total_cost_usd": sum(float(t.get("cost_usd", 0)) for t in telemetry),
            "policy_violation_runs": sum(bool(item.get("policy_violations")) for item in items),
            "dictionary_reuse_events": sum(int(t.get("dictionary_reuses", 0)) for t in telemetry),
            "preflight_rejections": sum(int(t.get("preflight_rejections", 0)) for t in telemetry),
            "traps": sum(int(t.get("traps", 0)) for t in telemetry),
            "replans": sum(int(t.get("replans", 0)) for t in telemetry),
        }

    return {
        "overall": metrics(results),
        "by_family": {family: metrics(items) for family, items in sorted(by_family.items())},
    }


def _bootstrap_ci(values: list[float], statistic: Callable[[list[float]], float], seed: int = 41) -> list[float] | None:
    if not values:
        return None
    rng = random.Random(seed)
    samples = []
    for _ in range(2000):
        draw = [rng.choice(values) for _ in values]
        samples.append(statistic(draw))
    samples.sort()
    return [samples[int(0.025 * len(samples))], samples[int(0.975 * len(samples))]]


def compare(left: list[dict[str, Any]], right: list[dict[str, Any]]) -> dict[str, Any]:
    lmap = {item["task_id"]: item for item in left}
    rmap = {item["task_id"]: item for item in right}
    shared = sorted(set(lmap) & set(rmap))
    success_delta = [float(bool(rmap[k]["success"])) - float(bool(lmap[k]["success"])) for k in shared]
    token_delta = []
    call_delta = []
    for key in shared:
        lt = lmap[key].get("telemetry", {})
        rt = rmap[key].get("telemetry", {})
        token_delta.append(
            float(rt.get("input_tokens", 0)) + float(rt.get("output_tokens", 0))
            - float(lt.get("input_tokens", 0)) - float(lt.get("output_tokens", 0))
        )
        call_delta.append(float(rt.get("model_calls", 0)) - float(lt.get("model_calls", 0)))
    mean = lambda xs: sum(xs) / len(xs)
    return {
        "paired_tasks": len(shared),
        "right_minus_left": {
            "success_rate": mean(success_delta) if success_delta else None,
            "success_rate_95pct_ci": _bootstrap_ci(success_delta, mean),
            "median_tokens": _median(token_delta),
            "median_model_calls": _median(call_delta),
        },
    }

