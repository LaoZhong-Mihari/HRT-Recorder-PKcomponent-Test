# HRT‑Recorder Pharmacokinetic Models

This README explains the algorithms used for each drug/route, key parameters and units, what was tuned, why we tuned it, how Estradiol / Testosterone now share one engine, and how the implementation evolved.

> 本文档已按当前代码重新同步，基准时间为 **2026-04-24**。本 README 以仓库内现行实现为准，尤其以 `PKSharedCatalog.json`、`PKparameter.swift`、`PKcore.swift` 和 Watch 端同名镜像实现为准。

---

## 0) 总览（模型架构）

**目标**：用一套轻量的、可解释的 PK 近似模型，覆盖常见 **Estradiol** 与 **Testosterone** 制剂和给药途径，在手机端与 Watch 端实时算出血药浓度–时间曲线与 AUC。

**当前范围**
- **模拟激素**：`estradiol`、`testosterone`
- **仅记录、不参与模拟**：`antiAndrogen`
- **Estradiol 路由**：`injection / patchApply / patchRemove / gel / oral / sublingual`
- **Testosterone v1 路由**：`injection (TC / TE / TU) / patchApply / patchRemove / gel / oral (TU)`
- **Testosterone sublingual**：**未实现**

**核心构件（与代码一一对应）**
- **MedicationCategory**：`estradiol | testosterone | antiAndrogen`
- **Compound**：统一替代旧的 `Ester`，当前包括：
  - Estradiol：`E2 / EB / EV / EC / EN`
  - Testosterone：`T / TC / TE / TU`
- **DoseEvent**：一次给药事件，带 `category`、`route`、`timeH`、`doseMG`、`compound` 与附加字段（如凝胶面积、贴片标称释放速率 µg/day、舌下 θ）。
  - 兼容旧数据：旧 payload 缺少 `category` 时，默认迁移为 `estradiol`；旧 `ester` 字段仍可解码进 `compound`。
- **ParameterResolver**：把事件映射为具体参数 `PKParams`（`k1/k2/k3/F`、双库比例、零阶速率等）。
- **ThreeCompartmentModel**：解析解工具箱：
  - 三室模型（吸收/释放 `k1` → 酯水解 `k2` → 游离激素清除 `k3`）
  - 单室 Bateman 形式（口服/凝胶/一阶贴片后备）
  - 双通路舌下模型（仅 Estradiol：快 = 黏膜，慢 = 吞咽→口服）
  - 贴片：有标称释放率时走零阶输入；否则走一阶“假库”近似
- **SimulationEngine**：把 `DoseEvent` 预编译为时间→量的函数，遍历时间点，线性叠加各事件中心室药量，再按激素对应单位换算为浓度，AUC 用梯形法则积分。
- **PKSharedCatalog.json**：现在是 **iPhone + Watch 共用** 的参数真源，统一保存：
  - hormone 级常量
  - compound 元数据
  - 各 route 的 PK 参数
  - 显示单位规则

**单 analyte 规则**
- 时间线 / 图表一次只模拟一个激素，**不会把 Estradiol 与 Testosterone 累加为同一条曲线**。
- **Estradiol 视图**：显示 `estradiol + antiAndrogen`
- **Testosterone 视图**：只显示 `testosterone`
- `antiAndrogen` 继续只做记录与提醒，不参与 PK 计算。

**单位与换算**
- `doseMG` 统一以 **active-hormone-equivalent mg** 存储：
  - Estradiol 系列统一换算为 **E2 当量**
  - Testosterone 系列统一换算为 **T 当量**
- 中心室药量计算单位也是 mg。
- 浓度输出按激素切换：
  - Estradiol：`conc = amountMG × 1e9 / Vd_ml`，单位 `pg/mL`
  - Testosterone：`conc = amountMG × 1e8 / Vd_ml`，单位 `ng/dL`
- 体分布体积：`Vd = vdPerKG × BW`，其中 `vdPerKG` 当前对两种激素都默认为 **2.0 L·kg⁻¹**（可在设置中调整）。
- `CompoundInfo.toActiveFactor` 只负责当量换算与显示，不在运行时重复乘进 `F`。

---

## 1) 公共参数（`PKSharedCatalog.json` + `PKparameter.swift`）

### 1.1 hormone 级常量（当前实现）

| 激素 | 浓度单位 | `vdPerKG` | `kClear` | 对应 t½ | `kClearInjection` | 对应 t½ | `patchFallbackK1` | `patchReleaseScale` | `gelK1` | `gelFmax` |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Estradiol | `pg/mL` | 2.0 L·kg⁻¹ | 0.41 h⁻¹ | 1.69 h | 0.041 h⁻¹ | 16.91 h | 0.0075 h⁻¹ | 1.000（默认） | 0.022 h⁻¹ | 0.06 |
| Testosterone | `ng/dL` | 2.0 L·kg⁻¹ | 0.60 h⁻¹ | 1.16 h | 0.03 h⁻¹ | 23.10 h | 0.0051 h⁻¹ | 3.770 | 0.0553 h⁻¹ | 0.226 |

> 这里的 `kClear` / `kClearInjection` 都是**模型参数**。尤其是 injection 路由的 `kClearInjection`，其主要职责是配合 depot 吸收复现曲线形状，**不是**直接可外推的人体生理清除率。

### 1.2 `kClear` 的来龙去脉

**Estradiol**
- 锚点主要来自 Estradiol 贴片移除后的终末回落：例如 FDA 标签与期刊资料显示，移除贴片后外源输入归零，后续下降更接近系统清除主导。
- 旧 README 里已说明：按贴片移除后 1–4 h 量级的回落去定 `kClear`；当前代码保持 **`kClear = 0.41 h⁻¹`**。
- **本次修正**：原 README 中注射专用 `kClearInjection` 仍写成 `0.05 h⁻¹`，而当前代码实际已经是 **`0.041 h⁻¹`**。README 现已按代码同步。

**Testosterone**
- `patch` 与 `gel` 继续使用 hormone 级 `kClear = 0.60 h⁻¹`，这样贴片移除后的约 70 min 回落能被保住。
- `oral TU` 现在改用 route-specific 的有效 `k3 ≈ 0.440 h⁻¹`，并加入约 **2.75 h** 的有效吸收滞后，因为单靠 `0.60 h⁻¹` 或无滞后 Bateman 无法同时命中 TLANDO 的 BID `Tmax / Cmax / Cavg0-24h`。
- 因此，`0.60 h⁻¹` 仍是 Testosterone 非注射路由的默认 prior，但不再假设所有 route 共享完全相同的有效清除。

### 1.3 注射专用 `kClearInjection`（有效参数说明）

**共同原则**
- 注射油剂的末端斜率往往主要受“从 depot 进入血液”的缓慢输入所支配，即典型 **flip-flop** 行为。
- 因此，注射路径单独使用 `kClearInjection`，是为了在简化模型中保住：
  - 峰时（`Tmax`）
  - 峰高（`Cmax`）
  - 长尾与稳态峰谷形状

**Estradiol**
- 当前使用 **`kClearInjection = 0.041 h⁻¹`**。
- 仅在 `route == .injection` 时生效，其它路由继续使用 `kClear = 0.41 h⁻¹`。

**Testosterone**
- 当前使用 **`kClearInjection = 0.03 h⁻¹`**，对应约 23.1 h 的表观终末常数。
- 这个值并不声称等于 Testosterone 的生理消除，而是与 `TC / TE / TU` 的双库 depot + 水解参数配合，尽量复现 label / study 所示的周级曲线形状。

### 1.4 当前文档与代码的一致性说明

本次同步主要修正了旧 README 中以下已经过时的 E2 描述：
- `kClearInjection`：旧文档 `0.05`，当前代码是 **`0.041`**
- oral `kAbsE2`：旧文档 `0.08`，当前代码是 **`0.32`**
- README 旧文案中的 “E2 equivalent” 现统一泛化为 **active-hormone-equivalent**
- 参数真源已从“分散在各 Swift 常量”统一成 **`PKSharedCatalog.json`**

---

## 2) 注射油剂（E2: EV/EB/EC/EN；T: TC/TE/TU）

### 2.1 模型与参数路径
- **模型**：两并联 depot 吸收/释放 → 酯水解 → 清除。
- “快库”主要控制峰时与峰高（`Tmax/Cmax`），“慢库”主要控制尾相与给药间隔下的谷值。
- 解析解使用三室模型：吸收/释放 `k1`、酯水解 `k2`、清除 `k3`。
- **参数来源**：`TwoPartDepotPK`、`CompoundHydrolysisPK.k2`、`InjectionPK.formationFraction`、`CorePK.kClearInjection`、`CorePK.depotK1Corr`。
- **代码入口**：`ParameterResolver.resolve(... case .injection ...)` → `ThreeCompartmentModel.injAmount(...)`。

### 2.2 Estradiol 注射关键数值（当前默认）

| 酯 | Frac_fast | k1_fast (h⁻¹) | t½_fast (h) | k1_slow (h⁻¹) | t½_slow (h) | k2 (h⁻¹) | t½_hydrolysis (h) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| EB | 0.90 | 0.144 | 4.81 | 0.114 | 6.08 | 0.090 | 7.70 |
| EV | 0.40 | 0.0216 | 32.08 | 0.0138 | 50.23 | 0.070 | 9.90 |
| EC | 0.229164549 | 0.005035046 | 137.66 | 0.004510574 | 153.67 | 0.045 | 15.40 |
| EN | 0.05 | 0.0010 | 693.15 | 0.0050 | 138.63 | 0.015 | 46.21 |

*注：Estradiol 注射路径当前使用 `k3 = kClearInjection = 0.041 h⁻¹`。*

### 2.3 Estradiol 注射 `formationFraction`

- 形成游离 E2 的经验分数由 `InjectionPK.formationFraction[compound]` 提供。
- 本项目输入剂量已按 **E2 当量** 输入，因此当前实现中 **`F = formationFraction`**，不再额外乘 `toActiveFactor`。

| 酯 | `formationFraction` |
| --- | ---: |
| EB | 0.1092237647 |
| EV | 0.0622582882 |
| EC | 0.117255838 |
| EN | 0.12 |

这些数值是**形状标定项**，用于把单次给药与稳态的 `Cmax/Tmax`、峰谷比、尾相拖尾拉到更接近项目目标曲线的量级。

### 2.4 Testosterone 注射关键数值（当前默认，v1）

| 酯 | Frac_fast | k1_fast (h⁻¹) | t½_fast (h) | k1_slow (h⁻¹) | t½_slow (h) | k2 (h⁻¹) | t½_hydrolysis (h) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TC | 0.35 | 0.016 | 43.32 | 0.0018 | 385.08 | 0.060 | 11.55 |
| TE | 0.35 | 0.022 | 31.51 | 0.0035 | 198.04 | 0.120 | 5.78 |
| TU | 0.30 | 0.005 | 138.63 | 0.001127743 | 614.63 | 0.015 | 46.21 |

*注：Testosterone 注射路径当前使用 `k3 = kClearInjection = 0.03 h⁻¹`。*

### 2.5 Testosterone 注射 `formationFraction`

- 当前 `TC / TE / TU` 的 `formationFraction` 分别为 **0.0678 / 0.0996 / 0.1294**。
- 这里的 `formationFraction` 现在明确承担 **经验暴露缩放项** 的角色：输入仍是 **T 当量 mg**，但 simplified 3C depot 模型仍需要一个额外 `F` 才能把 leaflet 里的 `Cmax` 拉回真实量级。
- 换句话说，它不再表示“酯换算是否已经做过”，而是表示“在 active-equivalent 输入口径下，为命中监管锚点所需的有效系统暴露分数”。

### 2.6 Testosterone 注射的来源、锚点与调参过程

本轮 Testosterone 注射并不是从 E2 参数“直接照抄”，而是遵循：
1. **先复用结构**：沿用现有的“两库 depot + 水解 + 清除”解析核；
2. **不复用数值**：单独为 `TC / TE / TU` 建一套参数；
3. **以主来源锚点定形状**：先抓 `Tmax / Cmax / terminal half-life / 第 N 天浓度`；
4. **再放入离线拟合工作流**：后续继续用 `pk_research/` 做更多交叉验证与边界搜索。

**TC（Testosterone Cypionate）**
- 主要锚点来自 FDA 标签：单次 200 mg IM 后，`Cmax ≈ 758 ng/dL`、`Tmax` 中位数约 **71.7 h**，注射后表观半衰期约 **8 天**。
- 当前参数取舍：
  - 快库 t½ ≈ 1.81 d，把峰位推到约 3 天
  - 慢库 t½ ≈ 16.0 d，配合 `k3 = 0.03` 形成约 8 天的表观终末相
  - `k2 = 0.06 h⁻¹`
  - `formationFraction ≈ 0.0678`

**TE（Testosterone Enanthate）**
- 主要锚点来自官方 SmPC：
  - depot 释放半衰期约 **4.5 天**
  - 250 mg IM 后血清 T 峰值通常在 **1.5–3 天**
  - 血清浓度在约 2 周回到接近基线
- 另一个监管摘要来源给出过“约 24 h 达峰、表观半衰期约 4.2 天”的更早峰位表述，因此当前 v1 采用的是**折中建模**：
  - 快库 t½ ≈ 1.31 d
  - 慢库 t½ ≈ 8.25 d
  - `k2 = 0.12 h⁻¹`
  - `formationFraction ≈ 0.0996`

**TU（Testosterone Undecanoate, injection）**
- 主锚点来自两类一手来源：
  - 说明书 / Zhang et al., 1998：4 名克兰菲特综合征患者单次 IM **500 mg** 后，给药前平均 T 低于 10 nmol/L，1 周平均 T 为 **47.8 ± 10.1 nmol/L**，`t1/2β = 18.3 ± 2.3 d`，`MRT = 21.7 ± 1.1 d`，约 50–60 天回到成年男性正常值下限附近。
  - AVEED / Nebido 类标签仍可作为给药间隔、长尾和给药方案外部校验，但当前 v1 的 TU 单次曲线优先按上面的 500 mg 说明书锚点标定。
- 当前参数取舍：
  - 快库 t½ ≈ 5.78 d，用于把峰位推到 7 天附近
  - 慢库 t½ ≈ 25.6 d，配合整体终末窗口复现约 18.3 d 的表观半衰期
  - `k2 = 0.015 h⁻¹`（t½ ≈ 46.2 h）
  - `formationFraction ≈ 0.1294`
  - 当前 500 mg 锚点下，模型在 7.2 d 达到约 47.8 nmol/L，14–60 d 窗口估算终末半衰期约 18.3 d；第 50 天外源贡献约 8.0 nmol/L。由于 App 不叠加给药前基础 T，50–60 天“回到 10 nmol/L 下限”只作为宽松校验。

### 2.7 数学形式（概念）
- 两个并联吸收库按 `Frac_fast` 和 `1 − Frac_fast` 分药量，分别以 `k1_fast` 与 `k1_slow` 进入“酯”室，水解为活性激素后以 `k3` 清除。
- 解析解采用三指数线性组合；当速率接近时采用保护分支避免数值异常。

### 2.8 模型尝试与取舍
- 单库吸收无法同时兼顾 `Tmax / Cmax / 长尾`，因此保留两库。
- 目前未为 Testosterone 注射额外新增第四室或蛋白结合池，而是先用有效 `k3 + depot` 组合近似 depot flip-flop。
- **这组 Testosterone 注射参数是 v1 工程近似**：
  - 已足够让 App 支持分 compound 的曲线模拟
  - 但还没有达到“完成多来源冻结”的程度
  - 仍需继续用 `pk_research/` 的 CSV 锚点 + Python 拟合工作流迭代

---

## 3) 贴片（E2 / T）

### 3.1 路由与参数
- **两种实现**：
  1) **零阶输入**：当事件带 `extras[.releaseRateUGPerDay]` 时，按标称 `µg/day` 转 `mg/h` 注入中心室，移除后按 `k3` 衰减。
  2) **一阶近似（后备）**：若未提供标称释放率，则用 hormone-specific 的 `PatchPK.generic` 做“假库”近似。
- **佩戴窗口**：`patchApply` 到后续 `patchRemove` 的时间跨度 `wearH`。
- **代码入口**：`ParameterResolver.resolve(... case .patchApply ...)` → `ThreeCompartmentModel.patchAmount(...)`。

### 3.2 数学形式

**零阶**

佩戴期（`0 ≤ t ≤ wearH`）：

$$
A(t) = \frac{\text{rateMGh}\cdot\text{patchReleaseScale}}{k_3} \,(1 - e^{-k_3 t})
$$

`patchReleaseScale` 没有显式配置时默认是 1.0；本轮只为 Testosterone zero-order patch 配置非 1.0 的锚点缩放。

移除后（`t > wearH`）：

$$
A(t) = A(\text{wearH})\, e^{-k_3 (t - \text{wearH})}
$$

**一阶后备**
- 以 `k1` 做“假库”吸收、`F = 1`。
- 移除时截断后续输入；实现上等价于只保留“佩戴结束前已经形成的药量”，之后按 `k3` 衰减。

### 3.3 Estradiol 贴片
- 若录入了品牌或规格所给的释放率，零阶模型通常最符合说明书表达。
- 未给释放率时，一阶后备使用 **`k1 = 0.0075 h⁻¹`**。
- 清除使用 Estradiol 的 **`k3 = 0.41 h⁻¹`**。
- 贴片移除后的终末回落，也是 Estradiol `kClear` 经验锚点的重要来源。

### 3.4 Testosterone 贴片
- 当前结构与 Estradiol 贴片相同，但使用 Testosterone 的非注射清除常数 **`k3 = 0.60 h⁻¹`**。
- 一阶后备时的 `k1` 使用 **`0.0051 h⁻¹`**。
- 主要一手锚点来自 ANDRODERM 标签：
  - “24 h 持续吸收”
  - `Tmax` 中位数约 **8 h**
  - 移除后表观半衰期约 **70 min**
  - 4 mg/day 系统 Day 28 平均 `Cavg ≈ 696 ng/dL`
- `patchReleaseScale ≈ 3.770`，用于把标称 4 mg/day 释放率映射到本引擎的有效中心室暴露。
- 因为手动录入时常常没有完整品牌速率信息，当前策略是：
  - **有释放率就优先零阶**
  - **无释放率才用一阶后备**

### 3.5 调参与选择
- 贴片的 label/说明书普遍以 **µg/day** 或 **mg/day** 的持续释放来表达，因此默认优先零阶。
- 一阶后备只用于缺资料的历史记录或快速录入，不应被解读为品牌级精确 PK 复现。

---

## 4) 经皮凝胶（E2 / T）

### 4.1 通用路由
- **模型**：单室一阶吸收 + 清除，`F` 表示有效系统暴露分数。
- **代码入口**：`ParameterResolver.resolve(... case .gel ...)` → `ThreeCompartmentModel.oneCompAmount(...)`。

### 4.2 Estradiol 凝胶（当前实现）
- **当前实现（稳定优先的简化版）**
  - `k1 = 0.022 h⁻¹`（t½ ≈ 31.5 h）
  - `F = 0.06`
  - 当前实现暂时忽略涂抹面积与剂量密度，直接返回固定 `(k1, F)`
- **本次 README 修正**
  - 旧 README 在探索历程中仍残留过时的 `k1 = 0.045` 说法；当前代码实际为 **`0.022`**
- **待办**
  - 重新引入剂量/面积依赖
  - 考虑皮肤浅层 depot 的短期平台释放

### 4.3 Testosterone 凝胶（当前实现，v1）
- **当前实现**
  - `k1 = 0.0553 h⁻¹`
  - `F = 0.226`
  - 清除使用 `k3 = 0.60 h⁻¹`
- **来源与锚点**
  - AndroGel 1.62% 官方标签提供了：
    - **Day 7** 的 24 h 血清 T 曲线
    - **Day 112** 的稳态 24 h 曲线
    - Day 112 时的总体 `Cavg` / `Cmax` 范围
  - 当前 v1 的目标不是精确复刻每个剂量档，而是先让引擎能反映：
    - once-daily application 后的日内起伏
    - 稳态曲线处于合理数量级
    - 夜间不会出现不合理的无限积累
- **取舍**
  - 仍沿用与 E2 类似的单室有效吸收模型
  - 还没有显式建“皮肤贮库 + 洗澡/残留膜层”过程
  - 因此它目前是 **可解释的近似，不是品牌级标签复刻**

---

## 5) 口服（E2 / EV / TU）

### 5.1 Estradiol / EV：模型与参数
- **模型**：单室 Bateman 吸收–清除。
- **当前默认参数**
  - `kAbsE2 = 0.32 h⁻¹`
  - `kAbsEV = 0.05 h⁻¹`
  - `bioavailability = 0.03`
- 在当前一室模型下：
  - E2 口服的峰位约落在 **2.75 h**
  - EV 口服的峰位约落在 **5.84 h**
- **实现说明**
  - README 旧版曾写 `kAbsE2 = 0.08 h⁻¹`，那已经过时；当前代码用的是 **`0.32 h⁻¹`**
  - `EV` 的口服水解效应在建模思路上仍视为“已折叠进更慢的有效吸收”；虽然 resolver 里保留了 `k2` 字段，但口服路径最终走的是 `oneCompAmount(...)`，也就是一室解析式

### 5.2 Estradiol / EV 口服调参说明
- `F = 0.03` 反映首过后仍进入系统循环的有效比例量级。
- `kAbsE2` 与 `kAbsEV` 的差异，用来体现：
  - E2 片起峰更快
  - EV 片需要更慢的“吸收 + 前体转化”综合过程

### 5.3 Testosterone 口服 TU（当前实现，v1）
- **模型**：双吸收通路的有效 oral 模型
- **当前默认参数**
  - `Frac_fast = 1.0`
  - `kAbs_fast ≈ 0.451 h⁻¹`
  - `lag_fast ≈ 2.75 h`
  - `F_fast ≈ 0.0259`
  - `F_slow = 0`
  - `k3 ≈ 0.440 h⁻¹`
- **主锚点来源**
  - TLANDO 官方标签：
    - 225 mg 早晚各一次随餐口服，**`Tmax` 中位数约 5 h**
    - 早/晚剂量后的平均 `Cmax` 约 **979 / 989 ng/dL**
    - 24 h 平均浓度 `Cavg0-24h ≈ 476 ng/dL`
    - 与食物同服时暴露显著高于空腹
- **当前模型的解释**
- 标签说明口服 TU 主要经淋巴吸收、避免明显肝首过；无滞后的单一 Bateman 很难同时命中 BID `Tmax / Cmax / Cavg0-24h`。
- 当前实现因此在 oral dual 配置中加入可选 `lagHoursFast / lagHoursSlow`。TLANDO v1 参数实际退化为“单一延迟吸收通路”：吸收滞后负责把峰位推到约 5 h，较快有效清除负责避免早晚两次给药时 24 h 平均暴露被过度抬高。
- **限制**
  - 还没有把“餐食脂肪含量”“双日 dosing”“前体 TU 与活性 T 分离显示”单独建模进去。

---

## 6) 舌下（仅 E2 / EV）

### 6.1 模型与参数（当前实现）
- **双通路**：把剂量按分流系数 **θ** 分为两支：
  - **快通路（口腔黏膜）**：`k1_fast = kAbsSL`，绕过首过；本项目按 active-equivalent 输入，因此快支默认 `F_fast = 1`
  - **慢通路（吞咽→胃肠）**：`k1_slow = kAbsE2 / kAbsEV`，进入 oral 通路，`F_slow = F_oral = 0.03`
- **EV 与 E2 的差异**
  - **舌下 E2**：无额外水解，双支都用一室 Bateman（`dualAbsAmount`）
  - **舌下 EV**：快支保留 `k2(EV)`，慢支直接走 oral 一室（`dualAbsMixedAmount`）
- **清除**
  - 继续使用 Estradiol 的 `k3 = 0.41 h⁻¹`
- **Testosterone**
  - **当前未实现**

### 6.2 黏膜分流 θ 的行为建模

早期文档曾尝试用相对生物利用度 RF 反推 θ，但那只能较粗略匹配 AUC，无法同时描述峰值和达峰时间，因此已弃用。

当前做法是把口腔当作最小系统：
- 固体剂量 `S` 以速率 `k_diss` 溶到口腔液相 `D`
- 溶解相 `D` 面临两个竞争路径：
  - 黏膜吸收 `k_SL`
  - 吞咽清除 `k_sw`

连立微分方程：

$$
\begin{aligned}
\frac{dS}{dt}&=-k_{\text{diss}}\,S\\
\frac{dD}{dt}&=k_{\text{diss}}\,S-(k_{\text{SL}}+k_{\text{sw}})\,D
\end{aligned}
$$

在用户的含服窗口 `T_hold` 内，真正走黏膜的比例定义为

$$
\theta(T_{\text{hold}})=\frac{1}{\text{Dose}}\int_{0}^{T_{\text{hold}}} k_{\text{SL}}\,D(t)\,dt
$$

超过 `T_hold` 的残留视为吞咽，进入慢支。

### 6.3 参数锚点与 UI 档位
- `kAbsSL = 1.8 h⁻¹`
- 依据舌下 E2 常见的约 1 h 峰位，反推得到合理快支吸收量级
- UI 不再使用 `theta_default`，而是四档：
  - `Quick`
  - `Casual`
  - `Standard`
  - `Strict`
- 推荐值：

| 档位 | 建议含服时长 | θ 推荐 | 典型范围 |
| --- | ---: | ---: | ---: |
| Quick | ≈ 2 min | 0.01 | 0.004–0.012 |
| Casual | ≈ 5 min | 0.04 | 0.021–0.057 |
| Standard | ≈ 10 min | 0.11 | 0.064–0.156 |
| Strict | ≈ 15 min | 0.18 | 0.115–0.253 |

### 6.4 一致性校验
- 当 `θ = 0` 时，舌下模型会严格退化为 oral
- EV 慢支不重复水解
- 这部分目前仍只对 Estradiol 系列开放，Testosterone 不提供 sublingual 入口

---

## 7) AUC 计算与稳态

- **AUC**：在 `SimulationEngine` 中对已合成的浓度轨迹采用梯形法积分得到。
- **AUC 单位按激素切换**
  - Estradiol：`pg·h/mL`
  - Testosterone：`ng·h/dL`
- **稳态**
  - 当前模型在实现上仍是线性系统
  - 重复给药时靠线性叠加自然收敛到稳态
  - 注射两库、贴片零阶、口服/凝胶的一室近似都保持可叠加性
- **注意**
  - 由于若干参数是“为了贴近标签曲线或项目目标曲线而做的经验参数”，不同路由间的绝对 AUC 可比性有限
  - AUC 更适合作为：
    - 同一路由下的相对比较
    - 同一个体的方案内优化

---

## 8) 探索历程（摘记）

以下按时间线回顾，方便未来溯源与复现。时间基于内部项目记录与代码历史。

- **2025‑06**：完成三室解析解（注射/口服/凝胶的公共内核），最初版本采用单库吸收。实现 AUC 计算与 pg/mL 输出。
- **2025‑07‑中**：
  - 贴片新增零阶输入路径，UI 支持 `releaseRateUGPerDay`。未提供标称时继续启用一阶近似。
  - 舌下路由曾从“含服时长”降维到固定双通路分流 θ，以减少用户面板负担并稳定曲线；该做法后续已废弃。
- **2025‑07‑末**：注射改为两库模型（`TwoPartDepotPK`），分别用 `k1_fast` 与 `k1_slow` 控制峰与尾；`formationFraction` 引入经验标定。
- **2025‑08‑初**：
  - 尝试“浓度反馈清除”（早期 hill/抑制式 k），在多事件叠加时出现不稳定与过拟合风险，回退为常数 `k3`。
  - 凝胶在“剂量/面积”非线性修正中出现系统性偏差，临时回退为常量实现；后续又把 E2 凝胶常数进一步收敛到当前的 `k1 = 0.022, F = 0.06`。
- **2025‑08‑中**：统一由 `ParameterResolver` 把各路由映射到 `PKParams`，`SimulationEngine` 负责事件窗口裁剪与 AUC 梯形法积分。
- **2025‑09‑03**：
  - 为 Estradiol 注射路径加入专用 `kClearInjection`
  - 重新标定 E2 注射两库参数
  - 在 README 中明确 `formationFraction` 与注射 `k3` 的“有效参数”属性
- **2025‑09‑22**：
  - 舌下：废弃 RF→θ 的反推，改为行为驱动的 θ 计算
  - UI：移除 `theta_default`，改为四档
  - 舌下 EV：改为快支 3C + 慢支 1C 的混合实现
- **2026‑03**：
  - 把原“Estradiol 专用链路”升级为 **Estradiol / Testosterone 多激素单引擎**
  - 引入 `MedicationCategory`、`Compound`、`SimulatedHormone`
  - `DoseEvent` 从 `ester` 演进为 `category + compound`，并保留旧数据兼容
  - `SimulationResult` 改为激素无关的浓度数组 + 单位元数据
  - 时间线 / 图表切成 `Estradiol / Testosterone` 双视图
  - iPhone 与 Watch 的 PK 常量收敛为同一份 **`PKSharedCatalog.json`**
  - 新增 Testosterone 的 `TC / TE / TU injection`、`gel`、`patch`、`oral TU` 支持
  - 在仓库内建立 `pk_research/` 作为离线锚点与拟合工作区
- **2026‑04‑24**：
  - 将 oral TU 锚点从“单次 225 mg 近似”修正为 TLANDO 标签的 **225 mg BID** 曲线
  - 为 oral dual 模型加入可选吸收滞后参数，并重新标定 TLANDO 的 `Tmax / Cmax / Cavg0-24h`
  - 补充 testosterone anchor 的结构化来源字段与拟合报告脚本
  - 修正 Watch 一阶贴片后备在 `patchRemove` 后未截断输入的问题
  - 发现 TE 锚点链接与实际使用的 Bayer 250 mg SmPC 不一致，改为指向 Bayer 原始 SmPC
  - 按 ANDRODERM 标签为 Testosterone zero-order patch 增加 `patchReleaseScale`，修正浓度量级

### 8.1 本次 Testosterone 扩展：锚点确定与调参流程

为避免 Testosterone 直接复制 E2 的做法，本轮采用了以下流程：

1. **先定结构**
   - 注射优先尝试复用现有“两库 depot + 水解 + 清除”
   - gel / patch / oral 先复用一室 / 零阶工具箱
2. **只用一手来源做首批锚点**
   - 监管标签 / DailyMed / SmPC / PubMed 原始研究优先
3. **统一口径**
   - 剂量统一换到 **active-hormone-equivalent mg**
   - 浓度统一到当前激素的显示单位：
     - Estradiol → `pg/mL`
     - Testosterone → `ng/dL`
4. **优先抓这些锚点**
   - `Cmax`
   - `Tmax`
   - 第 N 天 / 第 N 小时浓度
   - terminal half-life
   - steady-state `Cavg / Cmax / Cmin`
   - 能拿到的话再补全曲线
5. **离线拟合**
   - 在 `pk_research/data/` 录入标准化锚点
   - 用 `fit_route_parameters.py` 做带边界的随机搜索 + 局部扰动细调
6. **再决定哪些参数回写 Swift**
   - 当前只把“足够支持 v1 route 上线”的参数回写到 `PKSharedCatalog.json`
   - 但 README 明确保留其 **v1 / engineering default** 身份，等待后续更多来源冻结

---

## 9) 参考与依据（部分）

下列只列出与当前实现高度相关、且本次同步确实使用到的主要来源，非详尽清单。

### 9.1 Estradiol：既有来源（保留并继续有效）

**社区与技术文档**
- mtf.wiki：雌二醇凝胶（含经皮半衰期、实用注意事项）
  <https://mtf.wiki/zh-cn/docs/medicine/estrogen/gel>
- Transfem Science：注射、舌下、不同路由比较等
  <https://transfemscience.org/articles/injectable-e2-meta-analysis/>
  <https://transfemscience.org/articles/sublingual-e2-transfem/>
  <https://transfemscience.org/articles/e2-equivalent-doses/>
  <https://transfemscience.org/articles/oral-vs-transdermal-e2/>
- estrannai.se：Injection 三室模型与 Patch 算法参考
  <https://estrannai.se/docs/ingredients/>

**官方说明书 / 监管资料**
- Climara®（FDA 标签）：移除贴片后的回落与表观半衰期描述
  <https://www.accessdata.fda.gov/drugsatfda_docs/label/2001/20375s16lbl.pdf>
- FDA 临床药理综述 / 产品手册示例
  <https://www.accessdata.fda.gov/drugsatfda_docs/nda/99/020994_clinphrmr.pdf>
  <https://www.accessdata.fda.gov/drugsatfda_docs/label/2008/020375s026lbl.pdf>

**期刊 / 综述**
- Ginsburg ES et al. *Half-life of estradiol in postmenopausal women.* Fertil Steril. 1998
  <https://pubmed.ncbi.nlm.nih.gov/9473164/>
- Kuhl H. *Pharmacology of estrogens and progestogens: influence of different routes of administration.* Climacteric. 2005
  <https://pubmed.ncbi.nlm.nih.gov/16112947/>
- Oinonen et al. *Absorption and bioavailability of oestradiol from a gel, a patch and a tablet.* Eur J Pharm Biopharm. 1999
  <https://pubmed.ncbi.nlm.nih.gov/10465378/>

### 9.2 Testosterone：本次扩展使用的一手来源

**注射：TC**
- FDA 标签：*Testosterone Cypionate Injection*（单次 200 mg IM 后的 `Cmax / Tmax / t½`）
  <https://www.accessdata.fda.gov/drugsatfda_docs/label/2022/216318s000lbl.pdf>

**注射：TE**
- Bayer / Jenapharm SmPC：*Testoviron Depot 250*（depot 半衰期约 4.5 d，1.5–3 d 峰位）
  <https://www.bayer.com/sites/default/files/testoviron-depot-smpc-sep-2020-1.pdf>

**注射：TU**
- AVEED DailyMed：750 mg IM 后血清 T `Tmax` 中位数约 7 天；TU 前药浓度 Day 4 达峰
  <https://dailymed.nlm.nih.gov/dailymed/drugInfo.cfm?setid=f80f025b-17d8-40af-8739-20ce07902045>
- Zhang et al. 1998：TU 注射终末半衰期约 18–24 d，并可维持到 Day 50–60
  <https://pubmed.ncbi.nlm.nih.gov/9876028/>

**凝胶**
- AndroGel 1.62% DailyMed：Day 7 曲线、Day 112 / Day 364 稳态曲线
  <https://dailymed.nlm.nih.gov/dailymed/lookup.cfm?setid=f4e8d29b-8707-4d47-e053-2a95a90aecee&version=129>

**贴片**
- ANDRODERM DailyMed PDF：24 h 持续吸收、`Tmax` 中位数约 8 h、移除后表观半衰期约 70 min
  <https://dailymed.nlm.nih.gov/dailymed/downloadpdffile.cfm?setId=e58a5328-fdd9-40cb-a19f-8ed798989b9c>

**口服 TU**
- TLANDO DailyMed：225 mg 早晚两次口服的 `Tmax ≈ 5 h`、`Cmax` 与 `Cavg0-24h`
  <https://dailymed.nlm.nih.gov/dailymed/lookup.cfm?setid=4b0b92e9-6d3c-a0e5-e1c7-342999f72580>

### 9.3 研究与拟合流程（仓库内）

- `pk_research/README.md`
- `pk_research/data/anchors_template.csv`
- `pk_research/scripts/validate_pk_shared_catalog.py`
- `pk_research/scripts/fit_route_parameters.py`
- `pk_research/scripts/report_testosterone_anchor_fit.py`

> 说明：当前 Testosterone 常量已经进入引擎并支持 UI / Watch 端使用，但仍应视作 **v1 engineering defaults**。后续应继续补充更多论文、标签与临床试验数据，再做 route-by-route 冻结。

---

## 10) 局限

- **个体差异未建模**：年龄、SHBG、肝功能、BMI、并用药、注射部位/溶剂等都可能改变真实暴露。
- **Testosterone 仍在 v1 阶段**：
  - 注射 `TC / TE / TU`
  - patch / gel / oral TU
  已经能跑，但还缺更多独立来源交叉验证。
- **Testosterone sublingual 未实现**。
- **凝胶尚未显式建皮肤贮库**：E2 和 T 都还是有效一室近似。
- **patch fallback 是近似**：只有录入了标称释放率时，零阶模型才更接近品牌标签语义。
- **口服 TU 仍是粗粒度近似**：没有单独建食物影响与淋巴吸收动力学。
- **AUC 的跨路由可比性有限**：尤其 injection 路由含有效参数，适合个体内优化，不适合作为严格跨制剂生物等效判断。
- **测试仍需继续完善**：当前已有完整构建与共享 catalog 自检，但独立 XCTest 的 PK regression 覆盖仍需继续补强。

---

## 11) 快速对照：各路由实现要点

| 路由 | 解析/数值 | 输入 | 模型 | 关键参数 | F 的来源 |
| --- | --- | --- | --- | --- | --- |
| Estradiol 注射（EB/EV/EC/EN） | 解析 | E2 当量 mg | 两库吸收 + `k2` 水解 + `k3 = 0.041` 清除 | `Frac_fast, k1_fast, k1_slow, k2, k3` | `formationFraction` |
| Testosterone 注射（TC/TE/TU） | 解析 | T 当量 mg | 两库吸收 + `k2` 水解 + `k3 = 0.03` 清除 | `Frac_fast, k1_fast, k1_slow, k2, k3` | 经验 `formationFraction`，按 leaflet 锚点拟合 |
| Estradiol 贴片（零阶） | 解析 | `µg/day → mg/h` | 零阶恒速输入 + `k3 = 0.41` | `rateMGh, wearH, k3` | 固定 1.0 |
| Testosterone 贴片（零阶） | 解析 | `µg/day → mg/h` | 零阶恒速输入 + `k3 = 0.60` | `rateMGh, wearH, k3, patchReleaseScale = 3.770` | ANDRODERM `Cavg` 锚点 |
| Estradiol 贴片（一阶后备） | 解析 | E2 当量 mg | 一阶“假库” + `k3 = 0.41` | `k1 = 0.0075, k3` | 固定 1.0 |
| Testosterone 贴片（一阶后备） | 解析 | T 当量 mg | 一阶“假库” + `k3 = 0.60` | `k1 = 0.0051, k3` | 固定 1.0 |
| Estradiol 凝胶 | 解析 | E2 当量 mg | 单室 Bateman（简化常量版） | `k1 = 0.022, F = 0.06, k3 = 0.41` | 常量 0.06 |
| Testosterone 凝胶 | 解析 | T 当量 mg | 单室 Bateman（leaflet-calibrated） | `k1 = 0.0553, F = 0.226, k3 = 0.60` | 常量 0.226 |
| 口服 E2 | 解析 | E2 当量 mg | 单室 Bateman | `kAbs = 0.32, F = 0.03, k3 = 0.41` | 常量 0.03 |
| 口服 EV | 解析 | E2 当量 mg | 单室 Bateman（有效 oral EV） | `kAbs = 0.05, F = 0.03, k3 = 0.41` | 常量 0.03 |
| 口服 TU | 解析 | T 当量 mg | 延迟吸收 oral TU | `lag_fast = 2.75 h, kAbs_fast = 0.451, F_fast = 0.0259, k3 = 0.440` | TLANDO BID 锚点拟合 |
| 舌下 E2 / EV | 解析 | E2 当量 mg | 双通路：快 = 黏膜，慢 = 吞咽→oral；E2 用 `dualAbsAmount`，EV 用 `dualAbsMixedAmount` | `θ, kAbsSL = 1.8, kAbs oral, k2(EV 快支), k3 = 0.41` | 快 1.0；慢按 oral F |
| Testosterone sublingual | 未实现 | — | — | — | — |
| Anti-androgen oral | 不模拟 | 记录剂量 | 仅记录 / 提醒 | `recordOnlyOralMedication` | 不参与 PK |

---

## 12) 实现细节摘抄

- **DoseEvent**
  - 现在持有 `category + compound`
  - 旧 `ester` 仍可解码到 `compound`
  - 缺少 `category` 的旧数据默认迁移到 `estradiol`
- **ParameterResolver**
  - 先按 `event.simulatedHormone` 取 hormone 级 `CorePK`
  - 再按 `route + compound` 解析具体 `PKParams`
  - `antiAndrogen` 直接返回全零参数，不参与模拟
- **SimulationEngine**
  - 构建时只纳入当前选中激素的事件
  - 浓度换算不再硬编码为 `pg/mL`，而是从 `SimulationDisplayMetadata.concentrationUnit` 取比例尺
  - 但为了兼容旧调用，`SimulationResult` 仍保留 `concPGmL` 这个旧别名；当激素是 Testosterone 时，它只是历史命名，不表示真实单位仍是 pg/mL
- **贴片**
  - 自动寻找后续 `patchRemove`
  - 零阶：佩戴内累积、移除后只剩指数衰减
  - 一阶后备：用 `oneCompAmount(...)` 形成“假库”近似
- **舌下**
  - `θ` 优先取显式 `sublingualTheta`
  - 否则读取 `sublingualTier`
  - 再没有时保底落到 `Standard`
- **phone / Watch 一致性**
  - 双端共用 `PKSharedCatalog.json`
  - Watch 本地按当前所选激素重算，不再依赖手机已经算好的某一条固定曲线
