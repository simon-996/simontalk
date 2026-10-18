# 明确清理未开始的准备

日期：2026-10-18。已实现本人明确确认后的准备清理，不调用上游、不恢复媒体；与[只读恢复](2026-10-18-readonly-recovery-client.md)和[周期清理](2026-10-17-preparation-recovery-and-cleanup.md)配合。

## 接口与事务

POST `/v1/practice-sessions/{sid}/discard-preparation`只接收`{"expected_epoch":0}`。expected_epoch须为0–2147483647的严格整数，额外字段拒绝。沿用认证、X-Account-ID、Web Origin/CSRF保护；锁序User→Practice→按epoch排序的Connection，等待User锁后重新鉴权。本人不可见记录返回404 practice_not_found，代次变化返回409 preparation_changed，不符合安全条件返回409 preparation_not_discardable。

完整历史必须恰好覆盖1..connection_epoch；每条termination_status均为not_started，无offer_digest、signalling_started_at或signalling_finished_at。历史行必须closed/failed且有ended_at，仅当前最新行可为preparing；父connecting必须恰好对应这条待准备连接，created/cancelled不得隐藏preparing。缺失连接历史视为证据不足，任何unknown、confirmed或上游信令历史都拒绝，即使最新行看似安全。只接受created/connecting或已安全cancelled的幂等结果。

先验证所有行，再一次提交：最新preparing改closed，父练习改cancelled，二者使用同一ended_at和cancelled_before_signalling原因。无连接的created可直接清理；过期但未开始上游的准备也可处理。已经安全cancelled返回原终态，不改时间或原因。保留所有行、配置、创建键、epoch、历史租约与观测，不采纳其他客户端租约。真实准入关闭不阻止此清理。

响应为既有PracticeOutput。操作与建连、信令、撤销等遵循同一锁序；清理先提交时后续offer不能调用网关，信令先持久unknown时清理拒绝。网络失败不代表没有提交；用户须刷新核实，不能把业务取消当作上游终止或费用确认。

## 客户端

恢复模型的canDiscardPreparation仅控制候选按钮，完整资格以服务器锁后结果为准。弹窗捕获原不可变快照；控制器要求当前仍是同一对象且可展示，刷新、账号变化、操作中或销毁后不能发送旧确认。仓库绑定原账号/id/expected_epoch，严格核对返回原id、epoch、创建时间、配置及cancelled/结束时间。

“保留准备”无请求，“确认清理”才POST。清理与读取串行，每操作独立HTTP、8秒总截止及单调复核，销毁取消。成功清除旧快照，仅说明这项准备已清理，仍须明确刷新才知道是否出现其他练习。4xx为拒绝、网络/超时/5xx/异常响应为未确认，均清除旧操作入口、不自动重试或读取。401/账号变化继续重新确认身份。unknown无清理按钮，local_closed不能改变此条件。

同一ApiClient及账号fork共享CSRF令牌/进行中的获取，避免独立HTTP轮换共享Cookie后使退出缓存失效。独立HTTP取消仍保留；旧请求的csrf_invalid仅能清除其所用的当前令牌，不自动重放写请求。跨页面令牌轮换仍由服务端校验。

证据与替身范围见[验证记录](../development/2026-10-18-preparation-discard-verification.md)。
