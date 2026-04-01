#!/usr/bin/env python3
"""Simple offline PK fitter for route / compound anchor data.

This is intentionally lightweight and dependency-free so it can run anywhere.
It is meant for exploratory fitting before promoting approved constants into
PKSharedCatalog.json.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class AnchorRow:
    source_id: str
    hormone: str
    compound: str
    route: str
    dose_active_eq_mg: float
    time_h: float
    concentration_target: float
    population_note: str
    anchor_kind: str


def load_catalog(repo_root: Path) -> dict:
    return json.loads((repo_root / "PKSharedCatalog.json").read_text(encoding="utf-8"))


def concentration_scale_for_hormone(hormone: str, catalog: dict) -> float:
    unit = catalog["hormones"][hormone]["concentrationUnit"]
    return {"pgPerML": 1e9, "ngPerDL": 1e8}[unit]


def convert_concentration(value: float, unit: str, target_hormone: str) -> float:
    target_unit = "pg/mL" if target_hormone == "estradiol" else "ng/dL"
    normalized = unit.strip().lower()
    if normalized == target_unit.lower():
        return value

    if target_unit == "pg/mL":
        mapping = {
            "pg/ml": 1.0,
            "ng/dl": 10.0,
            "ng/ml": 1000.0,
        }
    else:
        mapping = {
            "ng/dl": 1.0,
            "pg/ml": 0.1,
            "ng/ml": 100.0,
        }

    if normalized not in mapping:
        raise ValueError(f"unsupported concentration unit '{unit}' for hormone '{target_hormone}'")
    return value * mapping[normalized]


def convert_dose_to_active_equivalent(value: float, unit: str, is_active_equivalent: bool, compound: str, catalog: dict) -> float:
    normalized_unit = unit.strip().lower()
    if normalized_unit != "mg":
        raise ValueError(f"unsupported dose unit '{unit}', expected mg")
    if is_active_equivalent:
        return value
    compound_info = catalog["compounds"][compound]
    return value * (compound_info["activeMolecularWeight"] / compound_info["molecularWeight"])


def convert_time_to_hours(value: float, unit: str) -> float:
    normalized = unit.strip().lower()
    if normalized in {"h", "hr", "hour", "hours"}:
        return value
    if normalized in {"day", "days", "d"}:
        return value * 24.0
    raise ValueError(f"unsupported time unit '{unit}'")


def load_anchors(path: Path, route: str, compound: str, catalog: dict) -> list[AnchorRow]:
    rows: list[AnchorRow] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            if raw["route"] != route or raw["compound"] != compound:
                continue
            hormone = raw["hormone"]
            rows.append(
                AnchorRow(
                    source_id=raw["source_id"],
                    hormone=hormone,
                    compound=compound,
                    route=route,
                    dose_active_eq_mg=convert_dose_to_active_equivalent(
                        float(raw["dose_value"]),
                        raw["dose_unit"],
                        raw["is_active_equivalent"].strip().lower() == "true",
                        compound,
                        catalog,
                    ),
                    time_h=convert_time_to_hours(float(raw["time_value"]), raw["time_unit"]),
                    concentration_target=convert_concentration(float(raw["concentration_value"]), raw["concentration_unit"], hormone),
                    population_note=raw.get("population_note", ""),
                    anchor_kind=raw.get("anchor_kind", ""),
                )
            )
    return rows


def analytic_3c(t: float, dose_mg: float, fraction: float, k1: float, k2: float, k3: float) -> float:
    if t < 0 or dose_mg <= 0 or k1 <= 0:
        return 0.0
    k1k2 = k1 - k2
    k1k3 = k1 - k3
    k2k3 = k2 - k3
    if min(abs(k1k2), abs(k1k3), abs(k2k3)) < 1e-9:
        return 0.0
    t1 = math.exp(-k1 * t) / (k1k2 * k1k3)
    t2 = math.exp(-k2 * t) / (-k1k2 * k2k3)
    t3 = math.exp(-k3 * t) / (k1k3 * k2k3)
    return dose_mg * fraction * k1 * k2 * (t1 + t2 + t3)


def one_comp(t: float, dose_mg: float, fraction: float, ka: float, ke: float) -> float:
    if t < 0 or dose_mg <= 0 or ka <= 0:
        return 0.0
    if abs(ka - ke) < 1e-9:
        return dose_mg * fraction * ka * t * math.exp(-ke * t)
    return dose_mg * fraction * ka / (ka - ke) * (math.exp(-ke * t) - math.exp(-ka * t))


def predict_concentration(anchor: AnchorRow, params: dict, catalog: dict, body_weight_kg: float) -> float:
    hormone_config = catalog["hormones"][anchor.hormone]
    vd_ml = hormone_config["vdPerKG"] * body_weight_kg * 1000.0
    scale = concentration_scale_for_hormone(anchor.hormone, catalog) / vd_ml

    if anchor.route == "injection":
        frac_fast = params["frac_fast"]
        amount = analytic_3c(anchor.time_h, anchor.dose_active_eq_mg * frac_fast, params["formation_fraction"], params["k1_fast"], params["k2"], params["k3"])
        amount += analytic_3c(anchor.time_h, anchor.dose_active_eq_mg * (1.0 - frac_fast), params["formation_fraction"], params["k1_slow"], params["k2"], params["k3"])
        return amount * scale

    amount = one_comp(anchor.time_h, anchor.dose_active_eq_mg, params["f"], params["ka"], params["ke"])
    return amount * scale


def objective(anchors: list[AnchorRow], params: dict, catalog: dict, body_weight_kg: float) -> float:
    total = 0.0
    for anchor in anchors:
        prediction = max(predict_concentration(anchor, params, catalog, body_weight_kg), 1e-9)
        target = max(anchor.concentration_target, 1e-9)
        relative_error = (prediction - target) / target
        total += relative_error * relative_error
    return total / max(len(anchors), 1)


def random_point(bounds: dict[str, tuple[float, float]]) -> dict[str, float]:
    return {key: random.uniform(low, high) for key, (low, high) in bounds.items()}


def perturb(params: dict[str, float], bounds: dict[str, tuple[float, float]], scale: float) -> dict[str, float]:
    out: dict[str, float] = {}
    for key, value in params.items():
        low, high = bounds[key]
        span = high - low
        delta = random.uniform(-span * scale, span * scale)
        out[key] = min(max(value + delta, low), high)
    return out


def bounds_for_route(route: str) -> dict[str, tuple[float, float]]:
    if route == "injection":
        return {
            "frac_fast": (0.05, 0.95),
            "k1_fast": (0.001, 0.2),
            "k1_slow": (0.0005, 0.06),
            "k2": (0.005, 0.2),
            "k3": (0.01, 0.08),
            "formation_fraction": (0.01, 1.5),
        }
    if route in {"oral", "gel", "patchApply"}:
        return {
            "ka": (0.001, 2.0),
            "ke": (0.01, 2.0),
            "f": (0.001, 1.0),
        }
    raise ValueError(f"route '{route}' is not currently supported by this fitter")


def fit_parameters(anchors: list[AnchorRow], route: str, catalog: dict, body_weight_kg: float, iterations: int) -> tuple[dict[str, float], float]:
    bounds = bounds_for_route(route)
    best_params: dict[str, float] | None = None
    best_score = float("inf")

    for _ in range(iterations):
        candidate = random_point(bounds)
        score = objective(anchors, candidate, catalog, body_weight_kg)
        if score < best_score:
            best_params = candidate
            best_score = score

    assert best_params is not None

    for scale in (0.2, 0.08, 0.03):
        for _ in range(max(200, iterations // 10)):
            candidate = perturb(best_params, bounds, scale)
            score = objective(anchors, candidate, catalog, body_weight_kg)
            if score < best_score:
                best_params = candidate
                best_score = score

    return best_params, best_score


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="CSV anchor file")
    parser.add_argument("--route", required=True, help="route to fit")
    parser.add_argument("--compound", required=True, help="compound to fit")
    parser.add_argument("--iterations", type=int, default=3000, help="random search iterations")
    parser.add_argument("--body-weight-kg", type=float, default=70.0, help="body weight used for concentration conversion")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    catalog = load_catalog(repo_root)
    anchors = load_anchors(Path(args.input), args.route, args.compound, catalog)
    if not anchors:
        raise SystemExit(f"No anchors found for compound={args.compound} route={args.route}")

    params, score = fit_parameters(
        anchors=anchors,
        route=args.route,
        catalog=catalog,
        body_weight_kg=args.body_weight_kg,
        iterations=args.iterations,
    )

    results_dir = repo_root / "pk_research" / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    output_path = results_dir / f"{args.compound}_{args.route}_fit.json"
    payload = {
        "compound": args.compound,
        "route": args.route,
        "iterations": args.iterations,
        "body_weight_kg": args.body_weight_kg,
        "objective": score,
        "anchors": len(anchors),
        "parameters": params,
    }
    output_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")

    print(json.dumps(payload, indent=2, sort_keys=True))
    print(f"\nWrote {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
