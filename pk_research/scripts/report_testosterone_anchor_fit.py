#!/usr/bin/env python3
"""Write a compact testosterone anchor fit report.

The regression test is the pass/fail gate. This script emits the same metrics
as JSON so parameter changes can be reviewed without re-reading unittest output.
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
REGRESSION_SCRIPT = REPO_ROOT / "pk_research" / "scripts" / "test_testosterone_anchor_regression.py"
OUTPUT_PATH = REPO_ROOT / "pk_research" / "results" / "testosterone_anchor_report.json"


def load_regression_module() -> Any:
    spec = importlib.util.spec_from_file_location("testosterone_anchor_regression", REGRESSION_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not import {REGRESSION_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def summarize_anchor(anchor: dict, results: dict, regression: Any) -> dict:
    kind = anchor["kind"]

    if kind in {"cmax", "cavg"}:
        actual = results[kind]
        target = anchor["target"]
        return {
            "kind": kind,
            "target": target,
            "actual": actual,
            "relative_error": (actual - target) / target,
        }

    if kind in {"tmax", "terminal_half_life", "post_remove_half_life"}:
        actual = results[kind]
        target = anchor["targetHours"]
        return {
            "kind": kind,
            "targetHours": target,
            "actualHours": actual,
            "absolute_error_hours": actual - target,
        }

    if kind == "concentration_at":
        target = anchor["target"]
        target_hours = anchor["targetHours"]
        closest_time_h, actual = min(results["series"], key=lambda point: abs(point[0] - target_hours))
        return {
            "kind": kind,
            "target": target,
            "targetHours": target_hours,
            "actual": actual,
            "actualHours": closest_time_h,
            "relative_error": (actual - target) / target,
        }

    if kind in {"cmax_window", "tmax_window"}:
        points = [
            (t, c)
            for t, c in results["series"]
            if anchor["windowStartHours"] <= t <= anchor["windowEndHours"]
        ]
        tmax_h, cmax_value = regression.series_max(points)
        summary = {
            "kind": kind,
            "windowStartHours": anchor["windowStartHours"],
            "windowEndHours": anchor["windowEndHours"],
            "actualTmaxHours": tmax_h,
            "actualCmax": cmax_value,
        }
        if kind == "cmax_window":
            target = anchor["target"]
            summary["target"] = target
            summary["relative_error"] = (cmax_value - target) / target
        else:
            target = anchor["targetHours"]
            summary["targetHours"] = target
            summary["absolute_error_hours"] = tmax_h - target
        return summary

    raise ValueError(f"Unsupported anchor kind: {kind}")


def main() -> int:
    regression = load_regression_module()
    case = regression.TestosteroneAnchorRegressionTests()
    case.catalog = regression.load_catalog()
    case.anchor_groups = regression.load_anchor_groups()

    groups = []
    for group in case.anchor_groups:
        results = case._simulate_group(group)
        groups.append(
            {
                "name": group["name"],
                "route": group["route"],
                "compound": group["compound"],
                "source": group.get("source"),
                "sourceTier": group.get("sourceTier"),
                "sourceUrl": group.get("sourceUrl"),
                "anchors": [
                    summarize_anchor(anchor, results, regression)
                    for anchor in group["anchors"]
                ],
            }
        )

    payload = {"groups": groups}
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(payload, indent=2, sort_keys=True))
    print(f"\nWrote {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
