# 只读练习恢复客户端

日期：2026-10-18。偏好页的“未结束练习”已接入既有current与observations接口；仅明确点击后读取，没有自动请求、轮询、开麦、恢复媒体或控制连接。

同日后续增加[明确准备清理](2026-10-18-preparation-discard-api.md)作为单独确认后的写动作；本文描述的current/观测读取仍保持只读。清理不处理unknown、不代表上游终止。

## 入口与数据

PracticeRecoveryPanel不出现在首次难度引导；登录后的偏好页按账号创建作用域，点击“查看未结束练习”只GET current。空记录如实显示，没有预置练习；有连接时“查看连接记录”读取原连接的一页32条。查看更多从已确认游标继续；刷新重新读取current并清除所有旧观测，不能将旧连接的事实混入新连接。

PracticeRepository.loadConnectionObservations绑定X-Account-ID、session/connection路径、原client_instance_id/epoch和分页参数。ConnectionObservationPage只接受固定client_observed来源、严格枚举/整数/原因/带时区时间、唯一事件ID、递增序号、正确最大水位/总数/游标/has_more。每页列表不可变，允许序号缺口，最多32条；每连接最多256条。空页不会制造关闭事实。

每次GET是一份独立快照，跨页不承诺同一事务。后续总数/最大水位不得倒退，事件ID不可重复，累积数量不能超过总数；有更多页必须尚有未读事实，最后一页累计条数须与总数一致。拒绝异常页时保留已接受页和原游标，明确重试不跨过失败页。读完后想看新增事实需刷新状态，重新开始分页。

## 账号与生命周期

PracticeRecoveryController是一次账号作用域的ChangeNotifier。创建不联网，重复动作共享进行中Future。每次操作派生独立ApiClient/http.Client，总等待8秒，包括凭证读取与响应体；另用单调时间拒绝抢在延迟Timer前返回的超时结果。销毁立即取消等待、清除数据、关闭自己的HTTP客户端，迟到结果不能重新展示，共享账号API继续可用。

provider只随signedIn用户ID变化，偏好保存与busy不重建。账号变化或401清除旧状态/记录并提供“重新确认账号”，由明确操作调用既有账号恢复入口；网络/服务错误保留登录。错误只显示固定中文提示，不显示响应原文、内部ID或SDK异常。退出/切换账号会销毁原作用域，旧请求不在新账号下重试。无浏览器存储或跨进程操作日志。

## 证据呈现

视图标明数据是查询时的服务端记录，可刷新。业务练习、连接状态、远端终止证据和客户端观测分开显示：unknown仍为“远端是否结束尚未确认”，local_closed只为“客户端报告本地已关闭”；二者可同时存在。读取不采纳其他客户端身份，也不调用续租、取消、信令、创建或付费服务。客户端时间、租约到期或关闭事实均不能确认远端结束或费用。

现有实际准入/网关/协议仍关闭。原只读批次的非空路径仅由HTTP替身/模型夹具验证；后续[准备清理验收](../development/2026-10-18-preparation-discard-verification.md)已用独立测试库、测试准入和真实浏览器验证非空读取、清理及unknown观测，仍无供应商语音或媒体恢复证据。开发库不注入练习。端点见[当前恢复](2026-10-17-preparation-recovery-and-cleanup.md)与[观测契约](2026-10-18-connection-observations-api.md)，原批次证据见[验证记录](../development/2026-10-18-readonly-recovery-verification.md)。
