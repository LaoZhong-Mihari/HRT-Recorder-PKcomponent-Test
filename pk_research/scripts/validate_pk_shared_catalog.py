#!/usr/bin/env python3
"""Validate the shared PK runtime catalog used by iPhone and Watch."""

from __future__ import annotations

import json
from pathlib import Path


REQUIRED_HORMONES = {"estradiol", "testosterone"}
REQUIRED_COMPOUNDS = {"E2", "EB", "EV", "EC", "EN", "T", "TC", "TE", "TU"}
REQUIRED_INJECTION_COMPOUNDS = {"EB", "EV", "EC", "EN", "TC", "TE", "TU"}
REQUIRED_ORAL_COMPOUNDS = {"E2", "EV", "TU"}
REQUIRED_ORAL_DUAL_COMPOUNDS = {"TU"}
REQUIRED_SUBLINGUAL_TIERS = {"quick", "casual", "standard", "strict"}


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    catalog_path = repo_root / "PKSharedCatalog.json"
    payload = json.loads(catalog_path.read_text(encoding="utf-8"))

    errors: list[str] = []

    hormones = set(payload.get("hormones", {}).keys())
    if hormones != REQUIRED_HORMONES:
        errors.append(f"hormones mismatch: expected {sorted(REQUIRED_HORMONES)}, got {sorted(hormones)}")
    for hormone, config in payload.get("hormones", {}).items():
        if "patchReleaseScale" in config and config["patchReleaseScale"] <= 0:
            errors.append(f"hormone '{hormone}' patchReleaseScale must be positive")
    testosterone_config = payload.get("hormones", {}).get("testosterone", {})
    if "patchReleaseScale" not in testosterone_config:
        errors.append("hormone 'testosterone' missing patchReleaseScale")

    compounds = set(payload.get("compounds", {}).keys())
    missing_compounds = REQUIRED_COMPOUNDS - compounds
    if missing_compounds:
        errors.append(f"missing compounds: {sorted(missing_compounds)}")

    depot = set(payload.get("twoPartDepot", {}).keys())
    if depot != REQUIRED_INJECTION_COMPOUNDS:
        errors.append(f"twoPartDepot keys mismatch: expected {sorted(REQUIRED_INJECTION_COMPOUNDS)}, got {sorted(depot)}")

    formation_fraction = set(payload.get("formationFraction", {}).keys())
    if formation_fraction != REQUIRED_INJECTION_COMPOUNDS:
        errors.append(
            "formationFraction keys mismatch: "
            f"expected {sorted(REQUIRED_INJECTION_COMPOUNDS)}, got {sorted(formation_fraction)}"
        )

    hydrolysis = set(payload.get("hydrolysisK2", {}).keys())
    if hydrolysis != REQUIRED_INJECTION_COMPOUNDS:
        errors.append(f"hydrolysisK2 keys mismatch: expected {sorted(REQUIRED_INJECTION_COMPOUNDS)}, got {sorted(hydrolysis)}")

    oral = payload.get("oral", {})
    oral_kabs = set(oral.get("kAbs", {}).keys())
    oral_bioavailability = set(oral.get("bioavailability", {}).keys())
    oral_dual_absorption = set(oral.get("dualAbsorption", {}).keys())
    if oral_kabs != REQUIRED_ORAL_COMPOUNDS:
        errors.append(f"oral.kAbs keys mismatch: expected {sorted(REQUIRED_ORAL_COMPOUNDS)}, got {sorted(oral_kabs)}")
    if oral_bioavailability != REQUIRED_ORAL_COMPOUNDS:
        errors.append(
            "oral.bioavailability keys mismatch: "
            f"expected {sorted(REQUIRED_ORAL_COMPOUNDS)}, got {sorted(oral_bioavailability)}"
        )
    if oral_dual_absorption != REQUIRED_ORAL_DUAL_COMPOUNDS:
        errors.append(
            "oral.dualAbsorption keys mismatch: "
            f"expected {sorted(REQUIRED_ORAL_DUAL_COMPOUNDS)}, got {sorted(oral_dual_absorption)}"
        )

    sublingual = payload.get("sublingual", {})
    for field_name in ("recommendedTheta", "holdMinutes", "thetaRangeLow", "thetaRangeHigh"):
        keys = set(sublingual.get(field_name, {}).keys())
        if keys != REQUIRED_SUBLINGUAL_TIERS:
            errors.append(
                f"sublingual.{field_name} keys mismatch: "
                f"expected {sorted(REQUIRED_SUBLINGUAL_TIERS)}, got {sorted(keys)}"
            )

    if errors:
        print("PKSharedCatalog.json validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print("PKSharedCatalog.json validation passed.")
    print(f"- hormones: {sorted(hormones)}")
    print(f"- compounds: {sorted(compounds)}")
    print(f"- injection compounds: {sorted(depot)}")
    print(f"- oral compounds: {sorted(oral_kabs)}")
    print(f"- oral dual-absorption compounds: {sorted(oral_dual_absorption)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
