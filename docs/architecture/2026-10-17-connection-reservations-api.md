# 连接尝试与业务租约契约

日期：2026-10-17。实现范围是持久准备登记与业务失联检测；后续已新增默认关闭的[单次信令边界](2026-10-17-guarded-signalling-api.md)，尚无供应商适配、模型事件、媒体终止或费用结算。

## 准入与身份

所有接口需现有登录；Web写入继续要求允许的Origin、CSRF及X-Account-ID。所有权由认证身份推导，路径中的练习和连接必须同时属于本人。写入按User→PracticeSession→RealtimeConnection加锁，User锁等待后重新检查身份；退出不承诺取消已经通过检查的在途写入。

运行时UnavailableAdmission保持关闭。只有独立测试库中的明确策略替身接受新登记；相同key读取已登记结果不表示当前准入开放。新建重新检查当前permit与练习原始provider/region/model/config_id完全相符，不因模型配置变化重写历史快照；不接受客户端上游地址、密钥、状态或费用声明。

## HTTP

以下路径均以`/v1/practice-sessions/{sid}/connections`为前缀。

| 方法/后缀 | 输入 | 结果 |
| --- | --- | --- |
| POST 空后缀 | client_instance_id(UUID)、expected_epoch(严格非负整数)；UUID Idempotency-Key | 201连接对象；用户+key同输入重放当前对象，不续租、不另开连接；不同输入/练习复用key为409 |
| GET /{cid} | 无 | 200本人连接；他人、其他练习路径、不存在均404 |
| POST /{cid}/renew-lease | client_instance_id、epoch(严格正整数) | 200更新业务租约；只有最新、未到期、非unknown/终态的连接可续租 |
| POST /{cid}/cancel-preparation | client_instance_id、epoch | 200关闭尚未开始信令的准备；已终结not_started重放当前终态；已进入信令或上游未知409 |
| POST /{cid}/offer | client_instance_id、epoch、offer | 受限单次交换；先提交negotiating/unknown，再调用网关，有效答案仅进入configuring；实际网关固定关闭，详见信令契约 |

输出包括id、session_id、client_instance_id、epoch、configuration、status、termination_status、state_reason、last_seen_at、lease_expires_at、created_at、ended_at。configuration只有服务器公开配置标识，不含长期密钥或SDP。

练习详情新增connection_epoch，初始0；新登记在事务内分配epoch+1，客户端不能自行提升代次。新key必须携带当前epoch且没有占用连接。旧代次不能续租或推进新连接；对旧的已安全终结对象重放取消不会改变当前练习状态。

## 租约与终止证据

45秒是业务租约工程参数，不是供应商最大时长。新登记/有效续租以服务端时间设置截止，客户端时间和任意延长期均不接受。截止时刻相等即到期，续租不能复活已到期对象；到期状态提交后返回409 `connection_lease_expired`，客户端读取当前结果。

| 当前证据 | 到期结果 | 是否仍占用 |
| --- | --- | --- |
| preparing + not_started | failed、结束时间、lease_expired | 否，系统明确没有开始上游 |
| negotiating/configuring/ready/closing + unknown | unknown、无结束时间、lease_expired | 是，不能声称已终止或零费用 |
| unknown或已终态 | 扫描不重复修改 | unknown继续占用 |

登记可创建preparing/not_started、取消为closed/not_started、或安全到期为failed/not_started。受限信令用例另可将准备推进negotiating/unknown，成功进入configuring，失败保留unknown；真实运行的准入/网关仍关闭。未提供客户端设置状态/confirmed的入口，ready及可信终止仍待媒体集成；调用网关前必须先事务提交占用。

安全取消/到期后，所有尝试均未启动上游的练习可回created；存在历史上游证据则回interrupted。原准备取消接口额外检查连接占用和上游历史，禁止将已建/未知媒体当作未开始准备取消。未知连接也独立阻止创建新练习，避免父状态错误解除占用。

## 扫描与数据库约束

本地管理命令`simontalk-admin expire-connections --limit 100`处理一批到期对象，限制1–1000。锁顺序与接口相同，skip_locked跳过忙碌对象；锁后重读状态/截止/当前epoch，不能用旧候选覆盖续租或新代次。命令仅输出提交后的处理数量。正常API lifespan现每15秒执行同一连接扫描及安全闲置准备清理；业务截止及周期任务都不会执行上游终止。调度、事务和恢复边界见[恢复与清理](2026-10-17-preparation-recovery-and-cleanup.md)。

复合外键保证连接所属用户与练习一致；用户+创建key、练习+epoch唯一；每用户和练习各最多一条未终结连接。数据库拒绝closed/failed同时保留unknown或缺少结束时间的组合；它不验证供应商证据的真实性，可信状态转移仍由服务端用例负责，客户端没有改写终止证据的入口。删除、可信终止和连接事件后续按对应设计接入。

客户端已提供[账号绑定的HTTP仓库与准备生命周期](2026-10-17-client-preparation-lifecycle.md)，明确重试保留原key/epoch，后台停止并保守处理租约。尚无练习页面或供应商媒体接入；客户端reserved只表示preparing/not_started业务登记。
