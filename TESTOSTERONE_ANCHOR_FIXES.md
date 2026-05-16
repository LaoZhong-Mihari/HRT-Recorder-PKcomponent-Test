# Testosterone Anchor Fixes

## What Was Wrong

- 注射 `TC / TE / TU` 把 `formationFraction` 固定成 `1.0`，导致 active-equivalent 剂量在 simplified 3C 模型里几乎原样进入系统暴露，`Cmax` 整体高出 leaflet 数倍到一个数量级。
- 口服 `TU` 早期用单一 Bateman + `k3 = 0.60 h⁻¹`，随后又用“单次 225 mg”近似 TLANDO 的 24 h 标签曲线；这两种口径都无法真实表达 TLANDO **225 mg BID** 的 `Tmax / Cmax / Cavg0-24h`。
- Testosterone 凝胶常量 `k1 = 0.03 / F = 0.12` 对 AndroGel Day 112 稳态曲线明显偏低。
- Testosterone zero-order patch 曾把 ANDRODERM 4 mg/day 的 Day 28 `Cmax = 696 ng/dL` 误标成 `Cavg`，导致释放缩放略偏高。
- Watch 端贴片仍把佩戴时长硬编码成 `7 天`，和手机端按真实 `patchRemove` 截断的逻辑不一致。
- 时间线直接显示 `event.doseMG`，也就是 active-equivalent mg，不是用户通常按 leaflet 理解的 raw compound mg，容易误读录入和结果。
- 仓库只有结构校验，没有把 leaflet anchor 做成自动 regression test，所以参数偏掉后不会被自动发现。

## What Changed

- 重新校准了 `TC / TE / TU` 的 depot、`k2` 和 `formationFraction`，让共享 catalog 命中当前 anchor。
- 给 oral `TU` 加了可选吸收滞后和 route-specific `k3`，并按 TLANDO 225 mg 早晚两次给药重新贴住峰位、早/晚 `Cmax` 和 24 h 平均暴露。
- 重新标定了 Testosterone gel 与 patch fallback 常量。
- 新增并修正 `patchReleaseScale`，让 ANDRODERM 4 mg/day zero-order patch 的 `Cmax` 命中标签量级。
- 统一了 phone/watch 的 patch remove 行为，并把时间线剂量显示改回 raw compound mg。
- 新增 `pk_research/data/testosterone_anchor_targets.json` 和 `pk_research/scripts/test_testosterone_anchor_regression.py`，把 anchor 对齐变成可重复执行的测试。
