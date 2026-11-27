# 本人只读用量查询契约

日期：2026-11-25。在[语音回复用量观察](2026-11-25-voice-response-usage.md)与复盘尝试记录之上，提供本人只读聚合接口和界面入口，不发起模型或媒体调用，也不改变 schema（保持 `56bd3c921ab4`）。

## 1. 只读 HTTP 契约

| 请求 | 返回与规则 |
| --- | --- |
| `GET /v1/usage` | `account_usage_v1`，按当前账号聚合普通练习语音、逐句重练语音、复盘与重练评价尝试，以及待核对连接数与已删除练习数 |
| `GET /v1/usage/practices/{session_id}` | `practice_usage_v1`，返回本人某条未删除练习的连接、语音回复与复盘尝试用量；不存在、他人或已删除练习统一返回 `404 practice_not_found` |

两接口均为零写入查询，固定返回 `source: server_recorded`、`account_id`、`checked_at` 与 `latest_recorded_at`，沿用 Cookie/Bearer 及 `X-Account-ID` 核验身份。

- 语音分桶（`voice_ordinary` / `voice_rehearsal` / 单次 `voice`）统计已落库回复次数、已知输入与输出总 Token、文本与音频分项 Token，以及缺少总量（`incomplete_count`）或缺少分项（`detail_incomplete_count`）的次数；未知字段不冒充为零。
- 复盘分桶（`review`）按 `ReviewAttempt` 统计总尝试次数、已知输入与输出 Token，以及 `outcome_unknown` 或缺少 Token 的不完整次数。
- 删除练习正文后，原连接 `VoiceResponseUsage`（关联 `PracticeSession.deleted_at IS NOT NULL`）和 `ReviewAttempt`（`job_id IS NULL`）的无正文计量继续计入 `account_usage_v1`，通过 `deleted_practice_count`、`deleted_response_count`、`deleted_attempt_count` 标明已删除来源，不暴露已删练习 ID、响应摘要或任何原话。
- 存在占用中或 `termination_status = unknown` 的连接时，通过 `connection_pending_count` / `connection_pending` 提示可能仍有尚未入账的上游用量。所有数字仅为服务端已收记录统计，不等同实际应付账单或远端停费证明。

## 2. 客户端模型与界面边界

- `AccountUsageSummary` 与 `PracticeUsageSummary` 严格校验固定字段集、schema 版本、账号/练习归属、带时区时间、非负上限及计数组合一致性，异常响应按 `invalid_response` 拒绝且不保留旧快照。
- `AccountUsageController` 与 `PracticeUsageController` 构造静默（零请求），仅在用户明确点击“查看本人用量”或“查看本次用量”后发起单飞 `GET`，派生独立原账号 `ApiClient` 并受 8 秒单调时钟截止保护；`401` 或账号变化立即清空旧结果并转入 `aborted`，`dispose` 取消在途读取。
- `/account`（非首次引导）嵌入 `AccountUsagePanel`；`/practice/:sessionId/save-status` 在保留进入时仅 2 次既有保存状态 `GET` 的前提下，于“连接与用量”区嵌入按需读取的 `PracticeUsagePanel`。点击回调复验当前路由、账号与忙碌状态；成功删除练习后同步失效 `accountUsageProvider` 与 `practiceUsageProvider`。
