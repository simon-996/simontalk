# 本人练习历史查询契约

日期：2026-10-23。工程实现，沿用当前账号、练习、固化、保存文字及复盘契约；不增加模型或媒体动作。

## 1. 本人只读接口

| 请求 | 返回与规则 |
| --- | --- |
| `GET /v1/practice-history?limit=10&cursor=...` | `practice_history_v1`，本人有限摘要页，默认10项，允许1–20 |
| `GET /v1/practice-history/{session_id}` | `practice_history_detail_v1`，本人一项摘要；不存在和他人记录统一404 |

两者均返回`source: server_recorded`和`account_id`，继续通过既有Cookie/Bearer及`X-Account-ID`核验当前身份。列表返回`limit/items/next_cursor`，详情返回`item`。独立前缀避免与原`/v1/practice-sessions/{uuid}`冲突。

每项只返回以下列，不加载转写、反馈或完整配置/重练目标：

| 字段 | 来源与含义 |
| --- | --- |
| `id/kind/source_session_id` | 练习自身标识、ordinary/rehearsal及一级来源 |
| `status/created_at/ended_at` | 原业务状态、准备登记时间及结束登记时间；不推算有效时长 |
| `difficulty` | 当时配置的`effective_difficulty`；缺失为null，不套用当前偏好 |
| `completion_status` | 无固化登记为unregistered，否则ending/sealed |
| `coverage` | 固化记录的pending/complete/incomplete，未登记为null |
| `connection_pending` | 本人该练习存在占用状态或termination_status unknown的连接 |

保存状态与连接占用分别展示。sealed不证明可信终止，不将两段时间相减当作有效时长或费用，不生成成绩。

## 2. 游标与索引

排序为`created_at DESC, id DESC`，seek使用严格tuple小于，读取`limit+1`判断是否有下一页。游标为紧凑JSON数组`[account_id, UTC微秒ISO时间, session_id]`的无填充base64url，最长256字符；账号、类型、时区及规范编码必须一致。非法游标（包含日期换算越界）返回400 `history_cursor_invalid`，非法limit沿用422参数校验。

游标是位置而非授权凭据，每次查询仍限定当前账号。边界行被删除不影响继续读取；新记录通过刷新回首页获取。新增迁移`2d4836ab9c10`仅创建`practice_history_owner_seek(user_id,created_at,id)`索引，不改业务行；降级只移除该索引。

主摘要查询一次select、outerjoin completion、EXISTS连接占用；不逐条加载对象。账号认证查询另计。实际20,000条隔离普通记录下首/seek均使用该索引，无Sort，详见[数据库证据](../development/evidence/2026-10-23-practice-history-database.json)。这只证明该数据分布下的查询路径。

## 3. Flutter读取与返回

`/history`读取每页10项；`/history/:sessionId`读取独立详情。登录恢复和连接失败保留网址，读取历史无需先设置难度或申请麦克风。首页接“练习 / 记录 / 我的”。列表push详情，返回保留原页与滚动位置；刷新从首页重新核对。

严格模型核对schema/source/owner、字段组合、排序、重复、游标末项和请求边界。每次refresh/next/previous独立8秒，独立HTTP fork、单飞、取消及单调时钟检查；构造不请求，不自动重试。翻页网络错误保留已接受页及原游标，刷新撤下旧页；账号/404/409/非法响应清除内容，dispose后迟到不能发布。

sealed详情可进入既有保存文字和复盘，分别重新核验来源；通过`?from=history`明确返回详情。初进复盘只GET已有任务，原生成按钮仍需用户明确操作。未封存仅展示实际状态，重练可返回来源详情，不提供尚未实现的重练或删除操作。

## 4. 验收与边界

见[单元规格](../superpowers/specs/2026-10-23-practice-history-design.md)、[实施计划](../superpowers/plans/2026-10-23-practice-history.md)和[验收记录](../development/2026-10-23-practice-history-verification.md)。独立测试库的文字、反馈和重练种子只用于工程验证；不写入开发账号，不证明真实语音或模型质量。浏览器工具禁用期间保留实际点击及Previewer待验项。

## 点击时的导航资格（2026-10-23）

历史列表/详情回调在点击时读取当前账号与原controller的当前内容。需signedIn、非账号busy、owner一致且controller非busy；列表ID仍属当前页，详情item仍绑定当前URL。文字/复盘须仍sealed，目标/来源仍是rehearsal且有来源，关联仍为ordinary；删除须有当前item。刷新撤旧、账号变化或翻页后，旧widget回调不再跳旧目标，也不会拼出`/history/null`。账号操作中按钮禁用，结束恢复且不新增GET；读取提示只表示idle/reading。此守卫不替代服务端权限及有效性检查。[回归证据](../development/2026-10-23-history-action-guards-verification.md)。
