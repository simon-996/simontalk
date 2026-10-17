# 连接尝试登记与业务租约

日期：2026-10-17。沿用户持续开发授权执行；真实模型/预算/设备条件继续暂缓，不新增付费开关。

## 选择与范围

在已经完成的准备登记、WebRTC传输之后，先落实后端的连接身份与失联边界。相比直接实现供应商SDP代理（缺模型及费用条件）或只在客户端保存连接状态（重启/多标签会丢失占用），持久登记可以验证真实数据库中的代次、幂等与并发。它不表示模型已连接。

本批只提供连接准备登记、读取、续业务租约、取消尚未开始信令的准备，以及可重复运行的到期扫描CLI。没有SDP交换、媒体调用、最终话语、完成练习或用量结果。运行时仍使用UnavailableAdmission，真实新建连接503且不写入。

## 数据与安全

PracticeSession增加服务端connection_epoch（初始0）。RealtimeConnection持久保存所属用户/练习、UUID幂等键与请求摘要、client_instance_id、递增epoch、公开配置快照、状态、last_seen_at、lease_expires_at、termination_status、状态原因及结束时间。

数据库用复合外键保证连接与练习的所有者相同；用户+创建key、练习+epoch唯一；部分唯一索引限制每用户/练习最多一条占用连接。关闭/失败必须有结束时间且termination_status只能not_started或confirmed；unknown保持占用。公开响应不含密钥、SDP或可自选的上游地址。

所有写入沿用Web Origin/CSRF/账号绑定。加锁顺序统一为User→PracticeSession→RealtimeConnection；User锁后重新鉴权。输入严格拒绝owner、状态、供应商配置和客户端时钟。退出与已通过检查的在途写入仍可能并行，不把业务鉴权当作上游终止。

## 行为

- 创建输入client_instance_id和expected_epoch，必须UUID Idempotency-Key。本人同key同输入返回当前已登记对象，既不重开连接也不续租；跨练习复用key或输入改变409。新key必须符合当前epoch、没有占用，重新检查准入及原准备的供应商配置，随后在同一事务中分配epoch+1并把练习改为connecting。
- 初始租约45秒是工程参数，仅用于业务失联检测，不构成付费时限。续租必须是本人、相同client_instance_id、准确且仍为最新的epoch、未到期且非unknown/终态；用服务端时间更新，永不重新开放已到期状态。
- 只有preparing且termination_status=not_started可以取消。安全取消或到期后，如果本练习所有尝试都未启动上游，可回到created；存在历史真实上游则回到interrupted。已终结的not_started对象重放取消不改时间/当前练习，旧epoch不能推进新连接。
- 到期的preparing/not_started连接可failed并结束，因为系统明确没有调用上游；其他占用状态到期只能unknown，保留结束时间为空、练习interrupted与独占。客户端不能声称confirmed，不能通过续租/本地关闭解除未知上游占用。
- 当前没有上游调用入口，未来SDP网关必须在调用前事务性把preparing/not_started改成negotiating/unknown；本批扫描器兼容这些状态，但测试种子不证明真实网关存在。
- `simontalk-admin expire-connections --limit 100`单批最多1000条，使用skip_locked避免阻塞正在操作的账号；每次重新检查截止时间/代次，不因旧扫描结果覆盖刚续租或新连接。没有自动定时调度，后续持久运行器接入同一用例。

## 验证

使用独立PostgreSQL测试库先红后绿，覆盖默认503无写入、同key/不同key并发、跨账号/练习/epoch/实例、配置不变、未知占用、取消与到期竞态、User锁等待后撤销、数据库约束、进程重建和真实CLI。迁移只添加表、列、约束，不清空开发账号。后端回归/Ruff/Alembic及实际本地HTTP默认拒绝分别记录；未触及客户端时不把旧Flutter检查写成本轮结果。
