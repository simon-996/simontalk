# 练习媒体业务协调器

日期：2026-10-17。按持续开发授权推进，不重复审批。基线02e24d2；模型/预算/设备任务继续暂缓，不开放实际准入或增加无服务页面。

## 选择与范围

比较直接扩展准备控制器、从准备控制器转移在途租约、独立媒体控制器三种方案。原控制器的reserved和stopped含信令前安全取消语义，转移还涉及在途续租及原截止，直接改写会破坏已验证边界。本批选择独立的一次性PracticeMediaController，直接组合现有PracticeRepository、ApiRealtimeSignaller和RealtimeTransport；保留原控制器。重复的UUID生成抽成小工具，媒体租约定时器独立成文件，避免改变旧流程。

运行时provider随登录身份创建/销毁控制器，不自动登记练习、交换信令或请求媒体。协议工厂默认抛realtime_unavailable；供应商协议尚未实现。后端真实准入仍先拒绝创建，测试明确注入HTTP/传输/协议替身，生产不注入替身。

## 生命周期

状态为idle、preparing、connecting、configuring、active、localClosed。begin每控制器只开始一次，保存随机客户端/练习key/连接key；重复调用共享等待，完成于本地active或localClosed。不自动重试、恢复或重连。

先登记练习及连接，核对created和preparing/not_started、配置及代次，使用原连接请求起点建立保守单调租约；通过本地协议工厂后才创建信令和传输。begin之前/准备失败不申请麦克风。传输start只表示通道可用，进入configuring；协议适配器根据原始练习配置处理开放通道/原始事件，仅确认对应通道配置后才能调用activate。activate成功后才发布本地active；播放状态独立，playing不代表供应商终止或服务端ready。

协议端口仅提供channelOpened、receive、dispose；创建时收到受保护的send、confirmConfigured、fail回调。所有回调受账号、一次性控制器代次、单调截止和前台状态保护；只能在已知开放通道发送/确认。传输ready前最多缓冲32条/128KiB事件及8个通道，ready后先通知通道再按序交付事件；不记录原始JSON/SDP。协议实现不能绕过本轮默认关闭工厂。

媒体连接等待最多60秒；传输ready后的配置/激活总等待20秒。除定时器外还记录单调截止，在异步结果及协议/媒体回调前重新检查，事件循环延迟不能绕过阶段限制。15秒串行续租覆盖connecting/configuring/active；旧45秒截止在HTTP等待时保持有效，成功响应不能跨过旧截止续命。允许preparing/negotiating/configuring/ready且终止证据匹配的同一连接快照；收到unknown/终态、配置/账号变化、失联或过期立即停止本地媒体。计时参数不构成上游费用上限。

## 停止与证据

停止、后台、账号provider销毁、传输local_closed、协议失败、续租失败或任何截止：同步封闭控制器代次、停止媒体、取消独立signaller、释放协议/定时器、清空事件缓存，并立即完成begin等待。清理API不阻塞本地释放，晚到创建仅做安全清理，晚到事件/答案/activate/续租不能复活。

服务端释放单独记录notNeeded、pending、released、unconfirmed；localClosed只表示本地停止。尚未调用exchangeOffer时，按连接→练习安全取消，必要时读取到期终态，仅凭服务端not_started+结束证据发布released。创建结果未知则保留unconfirmed及原key。进入exchangeOffer之前先置signallingAttempted；此后停止不发送准备取消，不宣称上游结束，释放状态保持unconfirmed，后端占用由后续可信终止或恢复处理。默认创建503只表示本次未登记，无媒体或重试。

账号切换由provider立即dispose；直接使用类时，每次异步边界、回调和公开媒体操作都重验当前账号。后台返回不自动重启。静音只响应用户操作，播放不关闭上行。观测仅保留最后一条受限code及本地播放枚举，不形成持久记录或转写；服务器观测接口另做一组交付。

## 验证与暂缓

先写失败测试覆盖默认503不建媒体、一次性创建键、配置确认前不激活、早到事件、有界缓冲、串行续租/原截止、后台/账号切换/销毁、停止与晚到所有异步阶段、信令前安全取消及信令后不误取消。用真实ApiRealtimeSignaller配HTTP替身完成组合测试；运行全量Flutter、分析/格式、Node和Web构建/字体，按requesting-code-review独立只读审查。

本批不实现供应商配置/事件协议、可信终止、持久观测、创建key跨进程恢复或页面。实际服务仍关闭；测试配置确认和传输替身不能证明真实语音、物理麦克风或费用已验收。
