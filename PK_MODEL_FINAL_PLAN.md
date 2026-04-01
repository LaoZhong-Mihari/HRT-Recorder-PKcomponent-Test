# 为 Estradiol / Testosterone 构建多激素 PK 单引擎的最终计划

## Summary

- 最终权威计划文件固定为 `PK_MODEL_FINAL_PLAN.md`。
- 目标是把当前“雌二醇专用”链路升级为“多激素单引擎”：保留现有 `estradiol` 曲线行为不变，新增 `testosterone` 一等支持；`anti-androgen` 继续只做记录和提醒，不参与模拟。
- v1 的 testosterone 范围固定为：注射 `TC / TE / TU`、经皮 `gel / patch`、口服 `TU`；不做 testosterone `sublingual`。
- 存储口径统一为“活性激素当量 mg”；默认展示单位固定为 `estradiol = pg/mL`、`testosterone = ng/dL`。
- 时间线和图表改为 `Estradiol / Testosterone` 双视图切换：Estradiol 视图显示 `estradiol + antiAndrogen` 记录，Testosterone 视图只显示 `testosterone`。

## Interfaces and Data Model

- 在持久化模型、模板、导入链路和 Watch bridge 中新增 `MedicationCategory = estradiol | testosterone | antiAndrogen`；旧数据与旧 Watch payload 缺少该字段时默认迁移为 `estradiol`。
- 将当前仅适用于雌二醇的 `Ester` 泛化为 `Compound`，并新增统一元数据层，固定包含：显示名、所属 hormone、是否酯化前药、分子量、`toActiveFactor`。
- `Compound` 的 v1 枚举固定为：
  - Estradiol: `E2 / EB / EV / EC / EN`
  - Testosterone: `T / TC / TE / TU`
- `DoseEvent`、`MedicationDoseTemplate`、Watch 本地事件和桥接 payload 全部改用 `category + compound`；`recordOnlyOralMedication` 保留，仅用于 anti-androgen 继续排除出模拟。
- 所有录入 UI、提醒文案、摘要文案中的 `E2 equivalent`、`toE2Factor`、`e2EquivalentDoseText` 统一改成“active-hormone-equivalent”语义。
- route 可选范围固定为：
  - `estradiol`：维持当前全部 route
  - `testosterone`：`injection / patchApply / patchRemove / gel / oral`
  - `antiAndrogen`：仅 oral record-only
- `SimulationResult` 改成激素无关结构：保存通用浓度数组、显示单位、AUC 单位和当前 analyte 元数据；图表、轴标题、当前浓度、Watch 当前值全部从这些元数据取文案，不再硬编码 `pg/mL` 或 “E2 concentration”。
- 浓度换算公式固定为：
  - estradiol: `amountMG * 1e9 / Vd_ml -> pg/mL`
  - testosterone: `amountMG * 1e8 / Vd_ml -> ng/dL`
- 模拟入口改成单 analyte 模式；一次只计算当前查看激素的事件，绝不把 estradiol 和 testosterone 累加成同一条曲线。

## PK Engine and Modeling Rules

- 保留现有解析核工具箱不动，继续复用三室、双通路、一室、零阶贴片等工具；`ParameterResolver` 固定先按 `MedicationCategory` 进入 hormone-specific parameter library，再按 `route + compound` 取参数。
- Estradiol 只做结构搬迁和 README 对齐，不主动重调现有参数；除非回归测试或现有实现与文档明显矛盾且经确认属于错误，才做最小必要修正。
- Testosterone 的建模规则固定为：
  - `TC / TE / TU` 注射：两库 depot + 酯水解 + testosterone-specific clearance
  - `gel`：一室有效吸收
  - `patch`：有释放率时走零阶；否则走一阶后备
  - `oral TU`：有效一室 oral 模型
  - 不实现 testosterone `sublingual`
- 模型复用策略固定为：先复用现有数学内核，不直接复用 E2 数值参数；如果某个 testosterone route 在当前核上无法同时拟合 `Cmax / Tmax / 关键日浓度 / terminal half-life / steady-state peak-trough`，则只为该 route 单独调整模型，不改全局引擎。
- 参数语义固定拆成两层：`physiological priors` 与 `effective fitted parameters`。除 injection 外，hydrolysis / clearance 必须尽量贴近生理数据；injection 允许保留“工程有效参数”以复现 depot flip-flop 形状，但必须在代码和 README 中显式标注其不是直接的生理清除。
- phone 和 Watch 不再手工维护两套独立常量；PK 参数、compound 元数据和单位规则必须共享同一套源，保证两端同输入同输出。

## Evidence, Calibration, and Acceptance

- 在仓库内建立固定 research 工作流，用于 testosterone 参数锚定、交叉验证和 Python 拟合；Swift 只承载最终批准的参数，不在 App 内做探索性调参。
- 数据源优先级固定为：原始论文、监管标签/说明书、临床试验资料；二级综述和社区资料只能做补充校验，不能单独决定参数。
- 每条 PK 数据固定记录：compound、route、formulation、dose、是否 active-equivalent、采样时间、浓度、单位、人群、单次/稳态、来源 id、来源等级。
- 锚点固定覆盖：`Cmax`、`Tmax`、第 N 小时/第 N 天浓度、terminal half-life、steady-state peak、steady-state trough、可用全曲线序列。
- Testosterone 初始锚点固定使用已给定的官方/主文献资料：`TC`、`TE`、`TU injection`、`gel`、`patch`、`oral TU`；随后继续补充能找到的文献、临床试验和标签数据做交叉验证。
- 拟合流程固定为：先统一单位和 equivalent 口径，再做带边界的多起点优化，最后做局部细调；每轮输出参数表、误差摘要、锚点命中情况和拟合曲线图。
- 参数冻结条件固定为：
  - 至少有 2 份独立来源可用，或 1 份高质量全曲线来源加 1 份可核验锚点来源
  - 主锚点浓度误差优先落在原文给出的 CI/SD 内；若原文无分布信息，则主锚点误差不超过 20%，次锚点不超过 25%
  - `Tmax` 误差不超过报告值的 15%，或短时路由不超过 6 小时，短中效 injection 不超过 0.5 天，长效 injection 不超过 1 天
  - 终末相和稳态峰谷不能出现持续同方向系统偏差
- 未满足冻结条件的 testosterone route 不上线；README 中明确标为待补数据，而不是填入猜测参数。

## Implementation Order

- 第 1 阶段：完成多激素数据结构改造、旧数据迁移、UI 命名泛化和事件过滤切换，但保持现有 estradiol 输出不变。
- 第 2 阶段：把主 App 和 Watch 的 PK 元数据、compound 定义和参数表并到同一来源，消除双维护漂移。
- 第 3 阶段：对齐现有 README 与实际 E2 代码，至少修正现有 `kClearInjection`、injection `F` 语义、oral `kAbsE2`、gel 当前简化实现和 watch 同步策略的描述。
- 第 4 阶段：建立 testosterone research 数据集和 Python 拟合流程，先完成 `TC / TE / TU injection`，再完成 `gel / patch / oral TU`。
- 第 5 阶段：把通过冻结条件的 testosterone 参数回写到 Swift，并补完整 README 的 testosterone 章节、来源表和“生理参数 / 有效参数”说明。
- 第 6 阶段：完成回归测试、单位测试、事件过滤测试和 iPhone / Watch 一致性测试后，才允许开放 UI 中的 testosterone 模拟入口。

## Test Plan

- 新增 PK regression test target；若仓库当前没有现成 test target，则在本次实现中创建。
- 验收必须覆盖：
  - 旧 estradiol 历史数据、计划模板和 Watch 数据都能解码，且默认迁移为 `MedicationCategory.estradiol`
  - 现有 estradiol 曲线在结构改造后不回归
  - testosterone 各 route 能产生非负、可叠加、峰后回落的曲线
  - estradiol 显示 `pg/mL`，testosterone 显示 `ng/dL`，图表和轴标签随激素正确切换
  - Estradiol tab 只显示 `estradiol + antiAndrogen`，Testosterone tab 只显示 `testosterone`
  - anti-androgen 始终不进入模拟
  - 同一事件集在 iPhone 和 Watch 上、针对同一激素时得到一致结果
  - README 中已上线参数与代码常量一致，README 不再保留与实现冲突的旧描述

## Assumptions and Defaults

- anti-androgen 在 v1 仍然不影响 estradiol 或 testosterone 曲线，只做记录和提醒。
- README 以“当前代码真实行为 + 本轮批准的新 testosterone 行为”为准更新，不顺带重做无关的 estradiol 旧调参。
- v1 不做双 analyte 同图，不做 testosterone sublingual，不做数据不足 route 的猜测性支持。
- active-equivalent 的基准固定为 parent hormone：estradiol 系列换算到 `E2`，testosterone 系列换算到 `T`。
- Python 拟合产物是唯一的校准真源；Swift 和 Watch 只消费已批准的最终参数。
