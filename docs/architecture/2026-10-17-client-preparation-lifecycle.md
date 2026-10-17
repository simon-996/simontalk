# 客户端准备生命周期契约

日期：2026-10-17。实现位置为`apps/client/lib/features/practice/`。本模块消费已有练习/连接登记HTTP接口，当前不连接媒体、不申请麦克风、不发SDP或供应商事件。运行时后端仍使用UnavailableAdmission。

## 模块与入口

| 文件 | 责任 |
| --- | --- |
| practice_models.dart | 只读练习快照/公开配置/连接对象/当前登记恢复，解析UUID、代次、枚举、带时区时间和终止证据组合 |
| practice_repository.dart | 固定accountId；8项创建/详情/取消/续租/当前登记读取直接调用现有HTTP契约，核对返回归属/代次/配置 |
| practice_preparation_controller.dart | 单个准备流程、创建键、内存恢复、15秒串行续租与保守截止、后台停止和安全取消 |
| practice_providers.dart | 随登录账号绑定的autoDispose provider，创建作用域时不自动登记；目前尚未被练习页面消费 |

`begin(difficulty: ...)`只从idle开始；每个控制器拥有安全随机v4 UUID客户端实例、练习创建键、连接创建键。重复点击不发第二次登记。临时难度和原始expected_epoch在不确定重试中保持不变。成功reserved表示preparing/not_started业务准备，后续媒体协调器仍需处理信令、模型配置确认和本地媒体生命周期。

## HTTP身份保护

ApiClient的专用accountId和idempotencyKey参数分别写X-Account-ID与Idempotency-Key。账号在请求开始、CSRF载入、移动凭证读取和响应等待后检查；旧响应不能写回新账号状态。Web继续使用HttpOnly Cookie和CSRF，不写Bearer。仓库不接受任意目标URL、owner或供应商密钥。401/409/503等错误码保留，不自动重新登录或重放请求。

## 续租和停止

采用单调时钟，首次创建连接请求开始时间加服务端租约跨度作为保守本地截止；重放旧创建结果保留原开始时间。成功续租以该次请求开始时间重新计算。客户端墙钟不参与，服务端时间仍是最终裁决；业务租约没有费用封顶含义。

每15秒只发一条续租，旧截止定时器在请求期间继续有效。发请求前及处理成功响应前都重新核对旧本地截止，防止事件循环延迟使晚到响应延长旧租约。续租失败、后台、停止或销毁会撤销后续定时器；回前台不自动重启。当前控制器只管理信令前准备，不能直接承担真实媒体停止。

取消按连接→练习执行。只有服务端确认连接安全终结且termination_status=not_started，并确认练习cancelled后，才发布stopped。准备到期409会读取连接详情再判断；unknown、已开始信令或终止证据不足时保持blocked，占用由后端决定。取消网络失败保留uncertain。

## 明确重试与恢复边界

普通网络失败后，`retry()`复用原键和payload；不能调用begin生成第二套登记。停止后的retry只补齐曾发送但没有结果的登记，再立即安全取消：丢失练习结果不会顺便创建连接；丢失连接结果复用原连接key和expected_epoch。该恢复不启动续租或媒体。并发retry共享串行工作，不重复取消。账号改变时旧作用域不向新身份发清理操作。

在途响应晚到且身份仍匹配时会补做清理；超时后的未知结果需明确重试。键和原输入目前只在内存。已提供loadCurrentPreparation只读读取服务器当前占用，并有服务端定期安全清理；页面消费、按原key恢复未知请求及跨进程持久操作恢复仍待后续。读取其他客户端实例不自动接管/续租/取消，详见[恢复与清理](2026-10-17-preparation-recovery-and-cleanup.md)。整个应用关闭可能先关闭HTTP客户端，异步取消不能保证送达；不能声称退出应用或取消数据库准备已终止供应商媒体。

## 验证边界

成功登记、续租与取消目前由真实ApiClient加HTTP/时钟替身测试验证；没有打开开发库语音准入。实际本地HTTP仅验证匿名401和readiness200。此前后端独立PostgreSQL事务测试提供服务端证据，二者不能合并称为客户端到供应商的真实语音闭环。详见[本轮验证](../development/2026-10-17-client-preparation-verification.md)。
