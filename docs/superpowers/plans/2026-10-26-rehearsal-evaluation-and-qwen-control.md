# 重练改善评价与千问控制复验计划

> **For agentic workers:** use `superpowers:subagent-driven-development` to execute this plan continuously. Preserve existing uncommitted work; no commit, push, deployment or native build.

**Goal:** 接通已封存一级重练的两轴、有原话依据的改善评价，并在用户恢复授权的累计20元预算内针对新版千问验证结束/删除控制路径。

**Architecture:** 复用已有复盘任务、输入绑定、后台 worker 和不可变结果，不新增队列或表。普通结果线格式不变，`review_result_v1`允许一个可选的 `rehearsal_evaluation` 扩展；旧存量仍可读取。新重练生成必须带两个结论，绑定服务器重新核验的一级目标及子练习文字。模型只接收文字与局部索引，不接业务UUID。客户端严格解析可选扩展并展示两轴和本次原话。实时实测独立于生产准入，不把连接关闭当费用或远端回收证明。

**Tech Stack:** Python/FastAPI/SQLAlchemy/PostgreSQL17、Qwen文字网关、Dart/Flutter/Riverpod、现有 pytest/Flutter 测试与预览系统。

## Task 1: 后端改善评价

- [x] 在 `review_gateway.py` 为请求增加可选重练目标、输出增加可选评价；保留原构造调用兼容性。
- [x] 新建小型严格验证模块，评价结构为 `schema_version: rehearsal_evaluation_v1`、`target_hash`、`intent`、`target_issue`。每轴为 `status`、`explanation`、`evidence`。证据为子练习 `source_connection_id/source_turn_id/revision/exact_quote`。
- [x] 意图状态 `conveyed/changed/insufficient_evidence`；目标状态 `demonstrated/still_present/not_demonstrated/insufficient_evidence`。确定结论必须有本次合格用户原话证据；不把未展示等同掌握/失败。不判断发音或长期能力，不强求照抄建议。
- [x] worker 在 claim/dispatch/complete 及结果读取重新核验冻结来源；来源失效不保留目标相关结论。目标相关评估仅重练可用，新重练缺评估拒绝、普通练习带评估拒绝；无可评价文字仍零调用。结果 hash 包含扩展，有评价且零建议也为 succeeded。
- [x] `qwen_review_gateway.py` 使用条件提示与 strict schema；父目标只传必要文字、kind/basis和安全前文，证据用局部索引映射。配置指纹包含新增提示/Schema。不得放宽普通输出校验、未知结果不重试、租约/删除/账号门。
- [x] 先写能失败的纯验证、网关与实际API/SQL/worker组合测试；使用独立 `_test` 数据库，记录 RED/GREEN，Ruff和原有相关回归。
- [x] 独立规格复核，然后代码质量复核；修复后复核。

## Task 2: Flutter 接入

- [x] `review_models.dart` 严格解析可选评价并深不可变；保留旧结果读取，调整 succeeded/no_suggestions 一致性。
- [x] `review_page_view.dart` 使用现有页面和组件展示“意思表达”和“目标问题”及解释/本次引文；普通复盘不改展示，重练不派生二级。不得把无评价旧结果推断为改善。
- [x] 先模型/组件测试，再实现。涵盖错误枚举/额外键/空证据/旧结果、320宽/深色/200%字号/零建议有效评价；现有账号/路由门继续有效。
- [x] 采用 Flutter/UI 和预览 skills，补可交互组件预览，独立规格与质量复核。

## Task 3: 有界真实验证及交接

- [x] 依据官方当前文档，两次新版 realtime 连接分别核对控制路径：小型固定输入/最大输出、结束与实际 item 删除事件；全程截止且无自动重试、无麦克风。只落脱敏事件/用量，未知费用保持未知。
- [x] 新评价网关用少量固定英文实际样本，覆盖意思保留/偏离、改善/仍在/未展示，核对引用和未强制照抄。必要时用同一正式 worker 的独立数据库验证持久化和纯读。
- [x] 最终 API/Flutter 必要全量与格式分析；Web 构建和实际页面核验按变更范围执行，明确固定文字与真实媒体的边界。
- [x] 更新对应架构规格、路线/验证状态与 `HANDOFF.md`（用户恢复千问实测、累计20元）。保留所有原文件和私有配置，清理测试数据库/服务/临时私有探针，核对无Key泄露。

已有工作区含824个原文件，开工摘要与私有配置0600摘要存于本轮私有临时目录。真实通话B2/B6只有在控制契约和实际媒体均验收后才能记完成；供应商询问稿不发送。
