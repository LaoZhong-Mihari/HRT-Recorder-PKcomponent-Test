# PK Research Workflow

This folder is the offline calibration workspace for PK parameter updates, especially testosterone.

## Layout

- `data/`
  - normalized literature / label / trial anchors
  - templates and manually curated source tables
  - `testosterone_anchor_targets.json` for the approved runtime regression anchors
- `scripts/`
  - validation and fitting helpers
  - regression checks that compare runtime constants against documented leaflet anchors
- `results/`
  - generated summaries, parameter candidates, plots

## Workflow

1. Add anchor rows to `data/anchors_template.csv` or a route-specific derivative.
2. Normalize units and active-equivalent dose basis before fitting.
3. Validate the shared runtime catalog:

   ```bash
   python3 pk_research/scripts/validate_pk_shared_catalog.py
   ```

4. Run the anchor regression checks:

   ```bash
   python3 pk_research/scripts/test_testosterone_anchor_regression.py
   ```

5. Run route fitting:

   ```bash
   python3 pk_research/scripts/fit_route_parameters.py \
     --input pk_research/data/anchors_template.csv \
     --route injection \
     --compound TC \
     --iterations 4000
   ```

6. Review residuals and candidate parameters under `results/`.
7. Only after review, copy approved constants into `PKSharedCatalog.json`.

## Acceptance Rules

- Prefer at least two independent sources per route / compound.
- Validate both full-curve shape and anchor metrics.
- Treat injection `formationFraction` and `kClearInjection` as effective fitted parameters.
- Prefer physiological priors for non-injection hydrolysis and clearance wherever possible.
