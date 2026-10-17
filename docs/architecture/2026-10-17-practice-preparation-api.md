# 练习准备登记契约

日期：2026-10-17。本批只落实持久准备状态，不提供真实媒体、转写、反馈或历史页面。

## 边界与准入

应用真实运行使用关闭的语音准入策略；创建返回503 `realtime_unavailable`，数据库不写任何练习。没有通过环境变量打开一个空服务的开关。测试通过明确策略替身在`_test`库验证登记成功路径；未来真实策略须核对服务/地域/预算与能力证据，只执行本地准入，不在数据库锁内调用供应商。

通过真实准入后，登记保存服务器选定的供应商公开配置标识、当前偏好全量快照与版本。不同账号互不可见；客户端不指定owner、供应商URL、模型密钥或任意提示词。首批只允许`mode=free_chat`、可选`difficulty_override`，必须已完成个人初始难度。

## HTTP

所有端点均需现有认证；Web POST继续要求Origin/CSRF和X-Account-ID，保持多标签身份绑定。

| 方法/路径 | 输入与结果 |
| --- | --- |
| POST /v1/practice-sessions | JSON `mode: free_chat`、可选`difficulty_override`；必须UUID格式Idempotency-Key。成功201；同用户同key且规范化输入一致返回原登记及原快照，输入不同409 `idempotency_conflict` |
| GET /v1/practice-sessions/{sid} | 200本人准备状态与快照；他人/不存在404 `practice_not_found`，不返回SDP或凭证 |
| GET /v1/practice-sessions/current | 200本人当前练习及最新/占用连接，空时practice/connection均null；单SQL只读、不续租、不接管，未知占用优先 |
| POST /v1/practice-sessions/{sid}/cancel-preparation | 无body；只允许`created`取消为`cancelled`，重复返回同一终态；已进入建连/活动/未知终止状态409 `preparation_not_cancellable`，不声称上游已停 |

同用户创建请求通过锁定User行序列化，数据库部分唯一索引再次保证只能一个未终结练习。已有相同幂等登记先重放，再检查新请求准入；不同key不得绕过并发限制，409 `practice_in_progress`。没有自动按客户端计时释放未知连接。偏好更新不会修改已有快照。

快照分别保存原始偏好与effective_difficulty，临时覆盖不改写个人设置。重放登记不代表当前媒体准入仍然开放，未来每次真正建连都须重新鉴权与准入。锁后再次检查身份，拒绝等待期间已禁用/撤销的会话；已经通过身份检查的在途业务写入可能与退出并行，退出不是取消所有在途操作或终止上游的证据。

状态允许总纲中的created/connecting/active/interrupted/ending/completed/cancelled/failed；本端点只能创建与取消未建连准备。[连接登记与租约](2026-10-17-connection-reservations-api.md)已实现：练习详情包含connection_epoch，登记连接时事务性进入connecting，只有所有尝试均确定未调用上游且已安全终结时可回created。本取消接口同时检查连接占用与上游历史。无法确认终止时保留占用，不能因业务标记或超时重新允许付费连接；即使父状态异常终结，未知连接仍独立阻止新练习。

将来实现删除时必须保留幂等键的删除墓碑，防止迟到重试重建已删练习；本批没有删除接口，也没有清空历史。没有可靠练习内容时不产生复盘、成绩或已完成记录。

PracticeOutput现包含nullable state_reason；主动准备取消为cancelled_before_signalling。正常API生命周期已定期清理从未调用上游、无占用且闲置300秒的created准备，原因preparation_expired；保留行/原key，旧key重放终态。详情及当前登记查询边界见[恢复与清理](2026-10-17-preparation-recovery-and-cleanup.md)。

## 验证

测试覆盖默认拒绝无写入、缺少初始难度、快照不变、同key重放与不同输入冲突、不同账号key隔离、两次并发不同key仅一个成功、他人读取/取消404、取消幂等、活动状态不能取消、Web CSRF/账号绑定、进程/请求间持久性。对测试库运行迁移与核心42项账号回归；本地开发库只执行新增表迁移，不删除现有账号。
