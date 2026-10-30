# 本人练习删除契约

日期：2026-10-23。工程实现，沿用D13/D20及[内容保存与未知连接约束](2026-10-20-practice-completion-and-review-contract.md)。

## 1. 范围、确认与幂等

| 请求 | 规则 |
| --- | --- |
| GET `/v1/practice-history/{sid}/deletion-scope` | 本人可见目标及完整一级成员摘要，纯读，不创建确认任务 |
| DELETE `/v1/practice-history/{sid}` | `{scope_version}`与`Idempotency-Key`；同步原子清除内容后200返回凭据 |
| GET `/v1/practice-history/{sid}/deletion?key={uuid}` | 本人原请求凭据；缺失404 `deletion_receipt_not_found`不等于删除成功 |

scope返回`practice_deletion_scope_v1/source=server_recorded/account_id/session_id/kind/record_count/rehearsal_count/scope_version/connection_pending`。普通目标的record_count包含父与全部未删子，rehearsal_count为子数量；重练目标两项计数均为1。version为目标及按ID排序的完整成员ID/类型/父关系的canonical SHA256，不返回原句或成员清单。

提交沿用Origin/CSRF、X-Account-ID及当前身份。锁序User→按ID完整成员→连接，与已有准备/重练/反馈worker的owner锁协调；锁后重新读取成员及hash。不匹配409 `deletion_scope_changed`，没有部分删除，须重新读范围并明确确认。未知/不存在/他人目标统一404。删除JSON在解析前累计限制8KiB和5秒总接收时间，超限413/超时408，不信任Content-Length。

2026-10-24补齐Web HTTP边界：CORS明确允许DELETE及既有Content-Type/X-CSRF-Token/X-Account-ID/Idempotency-Key请求头，仅精确配置来源可携带凭证预检。OPTIONS不查身份、不访问数据库；它不代替实际DELETE的Cookie、Origin/CSRF和账号绑定。Web删除缺失或不匹配X-Account-ID均409；CSRF/Origin拒绝仍403，无内容删除和凭据写入。详见[修补验证](../development/2026-10-24-web-delete-verification.md)；实际浏览器Cookie与JavaScript链路仍待验，Web/API沿用同主机规则，不能混用localhost与127.0.0.1。

凭据为`practice_deletion_receipt_v1/source/account_id/session_id/request_key/scope_version/record_count/rehearsal_count/connection_pending/deleted_at`，仅保留无正文事实。同owner/key、同target及version返回原凭据；不同target/body为409 `idempotency_conflict`。不同key访问已删目标404，不凭空再报一次成功。connection_pending为受理时快照，不用旧凭据推断当前连接已结束。

## 2. 原子清除与最小墓碑

直接物理级联PracticeSession会误删未知连接证据，因此使用deleted_at可见性门与内容清除，同事务保存凭据：

- 普通目标包含全部一级重练，单子仅自身。数据库已有同账号ordinary父约束强制一级。
- 删除ReviewInput及级联job/result/action；删除PracticeCompletion及member固化快照；删除所有关联连接的最终文字、播放/前缀正文与客户端观测；清空重练目标对象及配置中的任意JSON字段。
- PracticeSession保留标识/父关系、创建去重摘要、时间和安全墓碑，业务status=completed、state_reason=content_deleted。completed在这里是业务终结，不是学习或可信媒体完成。
- 没有未知连接的墓碑configuration为空；未知占用墓碑仅保留恢复契约所需的schema、难度/无正文偏好和供应商配置白名单。连接仅保留供应商四字段及原安全/信令证据，无原话/SDP。
- ReviewAttempt的job_id置null，保留原无正文运行/未知结果/可选用量，未知用量不编0。已派发模型可能仍在返回；删除后无job/来源资格，晚到结果不能重建正文。

原own_preparation可见性门及历史/同级列表均排除墓碑；旧创建key不能复活配置。原正文GET与写入均拒绝已删目标，普通练习/复盘/保存文字等旧网址重新读取404。其他设备/独立客户端已经下载的文字需要刷新或重进才能获知远端删除，当前没有跨设备实时推送删除通知。本客户端明确确认删除成功后的读取清理见下节。

## 3. 连接占用独立

尚未开始信令的preparing连接可关闭为closed/not_started；终止unknown的连接标unknown并保留占用，按原offer证据登记blocked/capability_unavailable、attempts=0的核验。不会把删除当作可信终止，不自动清退额度。

current可继续返回墓碑及无正文连接状态；Flutter显示“内容已删除，原连接与用量仍待核对”，不提供正文/保存/复盘动作。原连接元数据及核验可只读，不能续租或重新连该练习；unknown仍使新练习409。当前缺真实供应商执行器，不能宣称远端音频或费用已停止。

## 4. Flutter确认流程

详情次级“删除记录”进入`/history/:sid/delete`。深链接恢复账号后仅GET范围，免设难度；默认键盘焦点“保留记录”。显示普通/单子完整数量与不可恢复、用量/连接影响，明确“确认删除”才写。操作8秒包含CSRF，独立fork、单飞、取消及单调截止；身份变化/离页不发布迟到成功。

写响应未知保留原scope/key/body，只能核对原凭据；404未找到凭据仍显示未知，之后才开放明确“确认重试原删除”，不生成新key。确定409等拒绝清确认，重新读取再决定。成功清除history/review/transcript、恢复读取、重练目标/资格/关联列表providers，回列表真实刷新，并提示数量或仍待核对连接。返回记录不隐式发送删除。

## 5. 迁移、证据与后续

迁移`3e5947bc0d21`在`2d4836ab9c10`之上新增deleted_at及practice_deletion_receipts（owner/key主键、无目标FK）。非空墓碑或凭据时拒绝降级，以免静默恢复可见性或丢失去重证据。已有数据库升级不删除任何业务行。

[验证报告](../development/2026-10-23-practice-deletion-verification.md)列出真实HTTP、Dart互通、重启、并发、晚到结果和未验范围。后续[独立清单与离线恢复](2026-10-23-deletion-restore.md)已补完整成员持久化与停服重放：迁移`4f6a58cd2e32`保留缺账号/成员的删除决定，非空拒降。它不代表完整计费/供应商删除或自动备份，保留期限执行仍待可靠性关卡。

### 删除成功后的本地scope补齐（2026-10-23）

[衔接验证](../development/2026-10-23-deletion-read-scopes-verification.md)已复现并修补遗漏的新读取scope：仍有订阅也会在可信凭据后dispose旧恢复/重练/列表及重验资格，晚到GET不能填回旧内容；保留、409或删除动作未确认不触发成功清理。新current仍可显示completed/content_deleted及unknown占用，不隐式终止。rehearsalProvider含创建动作，其本地未确认key也随当前flow结束；沿用成功返回历史关闭该页、key仅存当前控制器的契约，不自动重放/另建。Entry、Preparation、Media生命周期不被这一清理点失效。

### 删除页点击资格与可见范围（2026-10-24）

删除、范围重读、原凭据核对、原请求重放和保留按钮在激活时复验当前登录owner、账号busy、当前provider/controller及其忙碌状态。另验当前ModalRoute和GoRouter最新地址仍是本删除页，路由切走但尚未销毁时旧回调无效。账号busy同时禁用页面操作与PopScope；非读/删阶段的等待提示为“正在处理，请稍候…”。

确认绑定本次View实际展示的不可变scope实例，并要求当前仍ready；另一次读取即使已完成、页面尚未重建，也不能用旧按钮确认新的范围。重新渲染并明确确认后才发送新scope。未找到原凭据后的重放仍使用原key/body，账号忙碌结束不会自动执行操作；本人需再次明确操作。无效地址仍可保留并返回。控制器8秒/未知响应、可信凭据后的成功清理及连接占用规则未改。[验证](../development/2026-10-24-deletion-action-guards-verification.md)。

2026-10-24新增每次保存情况纯读页后，可信凭据同时失效savedPracticeStatusProvider。保留订阅的旧历史摘要/保存缺口一并清空；它只有GET，不含创建key、媒体或待补交队列。见[保存结果契约](2026-10-24-saved-practice-status.md)。
