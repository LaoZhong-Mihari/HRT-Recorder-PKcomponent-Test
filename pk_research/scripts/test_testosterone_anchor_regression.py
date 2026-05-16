#!/usr/bin/env python3
"""Regression checks for testosterone leaflet anchors.

These tests intentionally mirror the runtime math in Swift so the shared
catalog can be checked in CI without requiring an iOS simulator.
"""

from __future__ import annotations

import json
import math
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOG_PATH = REPO_ROOT / "PKSharedCatalog.json"
ANCHOR_PATH = REPO_ROOT / "pk_research" / "data" / "testosterone_anchor_targets.json"


def load_catalog() -> dict:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))


def load_anchor_groups() -> list[dict]:
    payload = json.loads(ANCHOR_PATH.read_text(encoding="utf-8"))
    return payload["testosterone"]


def raw_to_active_equivalent(raw_mg: float, compound: str, catalog: dict) -> float:
    info = catalog["compounds"][compound]
    return raw_mg * (info["activeMolecularWeight"] / info["molecularWeight"])


def concentration_scale(catalog: dict, hormone: str, body_weight_kg: float) -> float:
    vd_ml = catalog["hormones"][hormone]["vdPerKG"] * body_weight_kg * 1000.0
    unit = catalog["hormones"][hormone]["concentrationUnit"]
    scale = {"pgPerML": 1e9, "ngPerDL": 1e8}[unit]
    return scale / vd_ml


def analytic_3c(t: float, dose_mg: float, fraction: float, k1: float, k2: float, k3: float) -> float:
    if t < 0 or dose_mg <= 0 or fraction <= 0 or min(k1, k2, k3) <= 0:
        return 0.0

    tol = 1e-9
    scaled_dose = dose_mg * fraction

    if abs(k1 - k2) < tol and abs(k1 - k3) < tol:
        return scaled_dose * k1 * k1 * t * t * 0.5 * math.exp(-k1 * t)

    if abs(k2 - k3) < tol:
        delta = k1 - k2
        return scaled_dose * k1 * k2 * (math.exp(-k1 * t) + math.exp(-k2 * t) * (delta * t - 1.0)) / (delta * delta)

    if abs(k1 - k2) < tol:
        delta = k1 - k3
        return scaled_dose * k1 * k1 * (math.exp(-k3 * t) - math.exp(-k1 * t) * (1.0 + delta * t)) / (delta * delta)

    if abs(k1 - k3) < tol:
        delta = k2 - k1
        return scaled_dose * k1 * k2 * (math.exp(-k2 * t) + math.exp(-k1 * t) * (delta * t - 1.0)) / (delta * delta)

    return scaled_dose * k1 * k2 * (
        math.exp(-k1 * t) / ((k1 - k2) * (k1 - k3))
        + math.exp(-k2 * t) / ((k2 - k1) * (k2 - k3))
        + math.exp(-k3 * t) / ((k3 - k1) * (k3 - k2))
    )


def bateman_amount(dose_mg: float, fraction: float, ka: float, ke: float, t: float) -> float:
    if t < 0 or dose_mg <= 0 or fraction <= 0 or ka <= 0 or ke <= 0:
        return 0.0
    if abs(ka - ke) < 1e-9:
        return dose_mg * fraction * ka * t * math.exp(-ke * t)
    return dose_mg * fraction * ka / (ka - ke) * (math.exp(-ke * t) - math.exp(-ka * t))


def bateman_steady_state_amount(dose_mg: float, fraction: float, ka: float, ke: float, tau: float, t: float) -> float:
    if dose_mg <= 0 or fraction <= 0 or ka <= 0 or ke <= 0 or tau <= 0:
        return 0.0
    if abs(ka - ke) < 1e-9:
        total = 0.0
        for n in range(256):
            total += bateman_amount(dose_mg, fraction, ka, ke, t + n * tau)
        return total
    return dose_mg * fraction * ka / (ka - ke) * (
        math.exp(-ke * t) / (1.0 - math.exp(-ke * tau))
        - math.exp(-ka * t) / (1.0 - math.exp(-ka * tau))
    )


def series_max(series: list[tuple[float, float]]) -> tuple[float, float]:
    return max(series, key=lambda item: item[1])


def cavg(series: list[tuple[float, float]], step_h: float, window_h: float) -> float:
    return sum(value for _, value in series) * step_h / window_h


def terminal_half_life(series: list[tuple[float, float]], start_h: float, end_h: float) -> float:
    points = [(t, c) for t, c in series if start_h <= t <= end_h and c > 1e-9]
    n = len(points)
    if n < 3:
        raise AssertionError(f"Need at least 3 positive points to estimate half-life, got {n}")

    sx = sum(t for t, _ in points)
    sy = sum(math.log(c) for _, c in points)
    sxx = sum(t * t for t, _ in points)
    sxy = sum(t * math.log(c) for t, c in points)
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    if slope >= 0:
        raise AssertionError(f"Expected a negative terminal slope, got {slope}")
    return math.log(2.0) / (-slope)


class TestosteroneAnchorRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = load_catalog()
        cls.anchor_groups = load_anchor_groups()

    def test_anchor_suite(self) -> None:
        for group in self.anchor_groups:
            with self.subTest(group=group["name"]):
                results = self._simulate_group(group)
                self._assert_group(group, results)

    def _simulate_group(self, group: dict) -> dict[str, float]:
        hormone = "testosterone"
        body_weight_kg = group["bodyWeightKG"]
        scale = concentration_scale(self.catalog, hormone, body_weight_kg)
        compound = group["compound"]
        dose_active_eq_mg = raw_to_active_equivalent(group["doseRawMG"], compound, self.catalog)
        route = group["route"]

        if route == "injection":
            depot = self.catalog["twoPartDepot"][compound]
            fraction = self.catalog["formationFraction"][compound]
            k2 = self.catalog["hydrolysisK2"][compound]
            k3 = self.catalog["hormones"][hormone]["kClearInjection"]
            series = []
            for index in range(0, 24 * 120 * 2 + 1):
                t = index * 0.5
                amount = analytic_3c(t, dose_active_eq_mg * depot["fracFast"], fraction, depot["k1Fast"], k2, k3)
                amount += analytic_3c(t, dose_active_eq_mg * (1.0 - depot["fracFast"]), fraction, depot["k1Slow"], k2, k3)
                series.append((t, amount * scale))
            tmax_h, cmax_value = series_max(series)
            return {
                "cmax": cmax_value,
                "tmax": tmax_h,
                "terminal_half_life": terminal_half_life(
                    series,
                    group["anchors"][2]["windowStartHours"],
                    group["anchors"][2]["windowEndHours"],
                ),
                "series": series,
            }

        if route == "patch_first_order":
            ka = self.catalog["hormones"][hormone]["patchFallbackK1"]
            ke = self.catalog["hormones"][hormone]["kClear"]
            series = []
            for index in range(0, 24 * 8 + 1):
                t = index * 0.25
                series.append((t, bateman_amount(dose_active_eq_mg, 1.0, ka, ke, t) * scale))
            tmax_h, _ = series_max(series)
            return {
                "tmax": tmax_h,
                "post_remove_half_life": math.log(2.0) / ke,
            }

        if route == "patch_zero_order":
            ke = self.catalog["hormones"][hormone]["kClear"]
            release_scale = self.catalog["hormones"][hormone]["patchReleaseScale"]
            rate_mg_h = group["releaseRateUGPerDay"] / 24_000.0 * release_scale
            wear_h = group["wearHours"]
            series = []
            for index in range(0, int(wear_h * 4) + 1):
                t = index * 0.25
                amount = rate_mg_h / ke * (1.0 - math.exp(-ke * t))
                series.append((t, amount * scale))
            _, cmax_value = series_max(series)
            return {
                "cmax": cmax_value,
                "cavg": cavg(series, 0.25, wear_h),
                "series": series,
            }

        if route == "gel_steady_state":
            ka = self.catalog["hormones"][hormone]["gelK1"]
            ke = self.catalog["hormones"][hormone]["kClear"]
            fraction = self.catalog["hormones"][hormone]["gelFmax"]
            tau = group["doseIntervalHours"]
            series = []
            for index in range(0, 24 * 4 + 1):
                t = index * 0.25
                amount = bateman_steady_state_amount(dose_active_eq_mg, fraction, ka, ke, tau, t)
                series.append((t, amount * scale))
            _, cmax_value = series_max(series)
            return {
                "cmax": cmax_value,
                "cavg": cavg(series, 0.25, 24.0),
            }

        if route == "oral":
            dual = self.catalog["oral"]["dualAbsorption"][compound]
            ke = dual["kClear"]
            lag_fast = dual.get("lagHoursFast", 0.0)
            lag_slow = dual.get("lagHoursSlow", 0.0)
            dose_times = group.get("doseTimesHours", [0.0])
            series = []
            for index in range(0, 24 * 4 + 1):
                t = index * 0.25
                amount = 0.0
                for dose_time_h in dose_times:
                    tau = t - dose_time_h
                    amount += bateman_amount(
                        dose_active_eq_mg * dual["fracFast"],
                        dual["bioavailabilityFast"],
                        dual["kAbsFast"],
                        ke,
                        tau - lag_fast,
                    )
                    amount += bateman_amount(
                        dose_active_eq_mg * (1.0 - dual["fracFast"]),
                        dual["bioavailabilitySlow"],
                        dual["kAbsSlow"],
                        ke,
                        tau - lag_slow,
                    )
                series.append((t, amount * scale))
            tmax_h, cmax_value = series_max(series)
            return {
                "cmax": cmax_value,
                "tmax": tmax_h,
                "cavg": cavg(series, 0.25, 24.0),
                "series": series,
            }

        raise AssertionError(f"Unsupported route in anchor file: {route}")

    def _assert_group(self, group: dict, results: dict[str, float]) -> None:
        for anchor in group["anchors"]:
            kind = anchor["kind"]

            if kind == "cmax":
                target = anchor["target"]
                tolerance = anchor["tolerance"]
                self.assertLessEqual(
                    abs(results["cmax"] - target) / target,
                    tolerance,
                    msg=f"{group['name']} cmax mismatch: expected {target}, got {results['cmax']}",
                )
                continue

            if kind == "cavg":
                target = anchor["target"]
                tolerance = anchor["tolerance"]
                self.assertLessEqual(
                    abs(results["cavg"] - target) / target,
                    tolerance,
                    msg=f"{group['name']} cavg mismatch: expected {target}, got {results['cavg']}",
                )
                continue

            if kind == "tmax":
                target_hours = anchor["targetHours"]
                tolerance_hours = anchor["toleranceHours"]
                self.assertLessEqual(
                    abs(results["tmax"] - target_hours),
                    tolerance_hours,
                    msg=f"{group['name']} tmax mismatch: expected {target_hours} h, got {results['tmax']} h",
                )
                continue

            if kind == "cmax_window":
                target = anchor["target"]
                tolerance = anchor["tolerance"]
                points = [
                    (t, c)
                    for t, c in results["series"]
                    if anchor["windowStartHours"] <= t <= anchor["windowEndHours"]
                ]
                tmax_h, cmax_value = series_max(points)
                self.assertLessEqual(
                    abs(cmax_value - target) / target,
                    tolerance,
                    msg=(
                        f"{group['name']} cmax_window mismatch: "
                        f"expected {target}, got {cmax_value} at {tmax_h} h"
                    ),
                )
                continue

            if kind == "tmax_window":
                target_hours = anchor["targetHours"]
                tolerance_hours = anchor["toleranceHours"]
                points = [
                    (t, c)
                    for t, c in results["series"]
                    if anchor["windowStartHours"] <= t <= anchor["windowEndHours"]
                ]
                tmax_h, _ = series_max(points)
                self.assertLessEqual(
                    abs(tmax_h - target_hours),
                    tolerance_hours,
                    msg=f"{group['name']} tmax_window mismatch: expected {target_hours} h, got {tmax_h} h",
                )
                continue

            if kind == "terminal_half_life":
                target_hours = anchor["targetHours"]
                tolerance = anchor["tolerance"]
                self.assertLessEqual(
                    abs(results["terminal_half_life"] - target_hours) / target_hours,
                    tolerance,
                    msg=(
                        f"{group['name']} terminal half-life mismatch: "
                        f"expected {target_hours} h, got {results['terminal_half_life']} h"
                    ),
                )
                continue

            if kind == "concentration_at":
                target = anchor["target"]
                target_hours = anchor["targetHours"]
                tolerance = anchor["tolerance"]
                points = results["series"]
                closest_time_h, actual = min(points, key=lambda point: abs(point[0] - target_hours))
                self.assertLessEqual(
                    abs(actual - target) / target,
                    tolerance,
                    msg=(
                        f"{group['name']} concentration_at mismatch: "
                        f"expected {target} at {target_hours} h, got {actual} at {closest_time_h} h"
                    ),
                )
                continue

            if kind == "post_remove_half_life":
                target_hours = anchor["targetHours"]
                tolerance = anchor["tolerance"]
                self.assertLessEqual(
                    abs(results["post_remove_half_life"] - target_hours) / target_hours,
                    tolerance,
                    msg=(
                        f"{group['name']} post-remove half-life mismatch: "
                        f"expected {target_hours} h, got {results['post_remove_half_life']} h"
                    ),
                )
                continue

            raise AssertionError(f"Unsupported anchor kind: {kind}")


if __name__ == "__main__":
    unittest.main()
