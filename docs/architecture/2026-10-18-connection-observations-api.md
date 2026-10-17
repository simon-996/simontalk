# 客户端媒体观测契约

日期：2026-10-18。观测是client_observed事实，不能作为供应商就绪、可信计量、终止或费用证据。读写均不改变练习/连接状态、租约或termination_status；真实语音准入、网关与客户端协议工厂继续关闭。

## 写入

`POST /v1/practice-sessions/{sid}/connections/{cid}/observations`使用现有认证，Web写入要求Origin、CSRF和X-Account-ID。服务端按User→Practice→Connection加锁，User等待后重验身份；连接必须属于本人及路径练习，client_instance_id/epoch必须与原连接相符。历史或终结连接可接收属于原实例的迟到事实，不覆盖新代次；当前新语音准入关闭不阻止本人观测记录。

| 字段/限制 | 契约 |
| --- | --- |
| client_instance_id / epoch | UUID / 严格正32位整数 |
| events | 1–16条，event_id唯一、sequence严格递增 |
| 每条event_id / sequence | 安全随机UUID / 严格1–2147483647 |
| code | requesting_microphone、negotiating、transport_connected、configuration_confirmed、microphone_active、playback_waiting、playback_blocked、playback_playing、playback_paused、muted、unmuted、local_closed |
| elapsed_ms | 严格0–86400000，客户端相对时间，未受信任 |
| reason | 只允许local_closed提供；user_stop、background、disposed、account_changed、lease_expired、connection_failed、configuration_failed、other |
| 接收边界 | 实际分块8KiB、总接收5秒；不信任Content-Length，超限413、超时408，解析前拒绝 |
| 额外输入 | 不允许文本、音频、SDP、模型原始JSON、上游URL、凭证、费用或终止声明 |

按连接event_id及sequence各自唯一。完全一致的event_id/摘要重放返回200，不另计数；改内容或占用同一sequence返回409 observation_conflict。未见事件的sequence低于当前最大值返回409 observation_sequence_stale；允许缺口，不声称记录完整。每连接最多256条，新写超限429 observation_limit_reached，完整重放仍可确认。整批校验后一起提交，冲突或超限不会部分写入。

200响应含固定source=client_observed、connection_id/client_instance_id/epoch、按请求顺序的acknowledged_event_ids、last_sequence及total_events。不使用创建登记的Idempotency-Key；事件ID与序号就是事实重放身份。

子表connection_observations仅保存事件身份、枚举/数值、规范摘要、服务器received_at和固定source。复合外键绑定原连接/客户端/epoch；删除连接或所属练习时级联。received_at是服务器接收事务时间，elapsed_ms不参与租约、计费或状态转移。没有更新/删除单条观测的客户端接口。

## 只读查询

GET同一路径只需本人登录；查询after_sequence默认0、范围0–2147483647，limit默认32、范围1–32。一条有界记录查询形成快照，再分页，返回身份/source/last_sequence/total_events、events、next_after_sequence和has_more。每条事件含原event_id/sequence/code/elapsed_ms/reason及received_at。空页的next_after_sequence保留输入游标。不存在、他人或错误练习路径均404；读取不接管、续租或关闭媒体。

所有响应沿用X-Request-ID/no-store、允许来源的CORS和脱敏错误；验证错误不回显原始输入。

## 客户端journal与媒体组合

ConnectionObservationJournal绑定源账号和原连接身份。最多64条内存待确认、每批16条串行发送；每条生成稳定UUID及递增序号。队列满时丢弃新普通事件并计数，关闭事实可替换未在途尾项；不会移除正在确认的事件。缺口和256服务端上限意味着可能丢失事实，不影响业务或费用裁决。

失败后暂停自动发送；retryPending由调用者明确触发，重用原事件身份/序号。只有确认完整的原身份和event_id集合才移除队列。每批派生独立HTTP客户端，包含CSRF/凭证/响应等待的8秒总截止，同时检查单调时间，晚确认不能抢在延迟Timer前被接受。请求完成、失败和取消只关闭自己的客户端，共享账号API继续可用。新账号或失效身份下丢弃旧内存队列；原批可能已提交，取消不能推断服务端没有记录。

finish不再接收新事实，尽力完成剩余队列，失败仍需明确重试；abort立即取消在途等待并清空队列。没有后台自动重放或浏览器存储。进程退出、断网、账号改变或队列/服务端上限都可能使最终关闭事实未送达。

媒体控制器按本地传输连接、协议确认与activate完成分别记录事实；播放/显式静音独立。停止先释放媒体，再记录唯一local_closed并finish；账号已变则abort。观测工厂或上报失败只影响observationErrorCode和待确认计数，不阻塞媒体与安全清理。provider仍不自动登记或申请媒体，默认503不创建journal。尚无恢复页面或持久操作恢复；查询API和journal不代表供应商语音验收。

证据见[本轮验证](../development/2026-10-18-connection-observations-verification.md)。
