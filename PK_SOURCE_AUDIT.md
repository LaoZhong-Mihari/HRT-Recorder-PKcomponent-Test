# Testosterone PK Source Audit

Date: 2026-04-24

本次审计目标是检查 TU 之外，睾酮路径是否还有“参数、锚点、来源口径不一致”的问题。Estradiol 暂不纳入本轮改动。

## Findings

| Area | Finding | Action |
| --- | --- | --- |
| TE injection | 旧锚点数值对应 Bayer Testoviron Depot 250 SmPC：250 mg IM 后约 20 ng/mL、1.5-3 d 达峰、depot release half-life 约 4.5 d；但 JSON 链接指向的 UK eMC 页面是另一套 200 mg/7 人数据。 | 保留参数，改 source URL 和文案为 Bayer SmPC。 |
| TU injection | 原先混用了 1000 mg/Nebido 类口径；用户给出的 500 mg TU 说明书锚点更具体。 | 已按 500 mg、47.8 nmol/L、18.3 d 终末半衰期重标定。 |
| Testosterone patch | zero-order patch 只使用标称 4 mg/day 释放率和 `k3 = 0.60`，预测 `Cmax` 约 198 ng/dL，低于 ANDRODERM Day 28 `Cmax` 696 ng/dL；同时旧锚点曾把该标签值误写为 `Cavg`。 | 修正为 `patchReleaseScale = 3.5078`，并用 `Cmax` regression anchor 覆盖。 |
| TC injection / AndroGel / oral TU | 当前结构化锚点与来源口径一致。 | 保持；继续由 regression 覆盖。 |

## Added Regression Coverage

- ANDRODERM 4 mg/day zero-order patch `Cmax`
- Bayer Testoviron source URL correction

## Main Sources

- Bayer Testoviron Depot 250 SmPC: https://www.bayer.com/sites/default/files/testoviron-depot-smpc-sep-2020-1.pdf
- ANDRODERM DailyMed: https://dailymed.nlm.nih.gov/dailymed/downloadpdffile.cfm?setId=e58a5328-fdd9-40cb-a19f-8ed798989b9c
- Zhang et al. TU injection: https://pubmed.ncbi.nlm.nih.gov/9876028/
