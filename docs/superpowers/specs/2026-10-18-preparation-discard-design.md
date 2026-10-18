# 未开始准备的明确清理

日期：2026-10-18，基线ecf560a。沿持续开发授权实施，真实模型、预算、硬件与原生任务暂缓；不推送或部署。

## 选择与范围

现有恢复入口只能查看；串行取消连接再取消练习存在中间状态和新代次竞争。采用新的单事务owner操作，页面明确确认后清理尚未开始上游的整项准备。它不是连接接管、媒体终止或历史删除。原信令前控制器的两个取消接口保持原契约。

## 后端

POST `/v1/practice-sessions/{sid}/discard-preparation`只接收严格非负32位expected_epoch，沿用Origin/CSRF/X-Account-ID及User锁等待后重新鉴权。按User→Practice→Connection顺序锁定，expected_epoch必须等于父行当前值；路径/代次共同绑定用户刚看到的准备。

只接受created/connecting，或已安全cancelled的幂等结果；其他父状态拒绝。连接历史必须完整覆盖1..connection_epoch，全部为not_started、没有offer摘要/信令时间，历史连接均closed/failed且有ended_at；仅当前最新连接可为preparing。缺行、旧代次占用、任何unknown/confirmed或信令历史均拒绝，不靠最新一条掩盖历史。全部先验证，再将最新preparing关闭并将父行cancelled，原因cancelled_before_signalling，保留原键、配置、租约历史和观测；一次提交，无上游调用。已安全取消返回原行，不改原结束时间或原因。过期但未开始的准备也可安全清理。

成功返回PracticeOutput；客户端核对原id/epoch/配置/时间及cancelled+ended_at。409 preparation_changed表示代次变化；409 preparation_not_discardable表示无法作为未开始准备处理，404继续本人可见范围。新语音准入关闭不阻止安全清理。和信令并发时，先持User锁的请求决定结果：清理先提交则信令不能调用网关，信令先提交unknown则清理拒绝。

## 客户端与交互

PracticeRecoveryController增加discardPreparation(original)及idle/working/succeeded/unconfirmed/refused状态，继续共用串行操作、独立HTTP、8秒总截止/单调检查和账号销毁取消。当前快照须为同一对象id/epoch且有可见的not_started安全候选；确认弹窗期间快照变化或busy不发送。这里只是展示候选，完整资格始终由服务端锁后判断。

偏好页候选显示“清理未开始的准备”。弹窗说明会取消同账号其他页面的这项准备、不删除历史，状态变化时服务器拒绝；“保留准备”不请求，“确认清理”才POST。清理不发创建/续租/offer或观测。成功只确认这项准备，清除旧快照并提示刷新查看当前状态；不虚构全账号没有新练习。超时/网络/5xx/响应异常为结果未确认，拒绝为需刷新，两者清除旧快照、禁用重复清理，均不自动GET/POST；刷新成功后由新的明确确认重新操作。身份变化/401清空旧数据并重新确认账号。

纯视图与对话框沿用主题/48最小控件/大字号换行；新增无服务的确认对话框预览。unknown不显示清理入口，local_closed不能改变资格。无新依赖、迁移、浏览器存储或供应商调用。

## 浏览器凭证修复

实际Cookie验收发现，独立操作HTTP客户端各自获取CSRF会轮换共享Cookie，使账号客户端的旧缓存导致首次退出403。同一ApiClient及其forkForAccount家族现共享令牌与签发中的Future，合并首次并发获取，但各自仍持有独立HTTP/取消信号。请求捕获所用令牌，只有该令牌仍是当前缓存时，csrf_invalid才清缓存，迟到旧拒绝不能抹去新令牌。失败不自动重放写操作。不同页面/进程的令牌轮换仍由服务端校验拒绝，再由本人明确重试；未放宽Origin、CSRF或Cookie规则。

## 验证

PostgreSQL测试验证空准备、跨客户端preparing、过期/已安全终结、完全重放、代次变化、未知/历史上游/缺失历史、所有权/严格输入/Web保护/锁后撤销、重复清理/新代次/信令竞争和原子状态不变。Dart先失败测试覆盖HTTP绑定及确认校验、候选筛选、陈旧弹窗、成功/拒绝/未知结果、超时与账号隔离；widget验证取消不发POST、确认才发送、unknown无入口、成功不冒充空current及窄屏/横屏/200%对话框。全量后端/Flutter、分析/格式、Node、Web/字体、独立审查；开发库不注入数据。
