# 客户端媒体业务协调契约

日期：2026-10-17。实现独立的一次性PracticeMediaController，组合真实业务HTTP仓库、ApiRealtimeSignaller和现有RealtimeTransport端口。运行时协议工厂和后端准入均默认关闭；provider尚未被页面消费，成功配置/媒体路径只由明确替身验证。

## 入口与责任

| 文件 | 职责 |
| --- | --- |
| practice_media_controller.dart | 单次准备、媒体/协议回调、账号/前台检查、续租结果、同步停止和释放证据 |
| connection_lease_watchdog.dart | 单调时钟、保守原截止、续租与截止定时器 |
| realtime_session_protocol.dart | 供应商协议端口和受保护send/confirmConfigured/fail回调；实际默认Unavailable |
| practice_media_providers.dart | 随signedIn账号创建/销毁作用域，读取不自动登记或申请媒体 |
| core/random_uuid.dart | 原准备与新媒体控制器共用的安全随机v4 UUID |

原PracticePreparationController继续只管理信令前流程，不传递在途租约给新控制器。每个媒体控制器保存自己的clientInstanceId、practiceKey、connectionKey，直接调用已有登记契约；业务后端仍强制单用户占用，不能因为本地有两个provider就并行建连。

`begin(difficulty: ...)`只启动一次；重复调用共享等待，完成于本地active或localClosed。没有自动重试、恢复或重连；原key仅在当前实例内存保留，跨进程未知请求恢复另行实现。默认503直接结束，不构造协议、信令或媒体。

## 准备与就绪

顺序是练习created→连接preparing/not_started→保守租约→本地协议工厂→独立HTTP signaller→传输start。等待任意一步时停止，晚到结果只能安全清理，不能继续后面的媒体流程。协议/信令/传输工厂内同步停止时，刚返回的对象也会释放。

| 本地状态 | 依据 |
| --- | --- |
| preparing | 正在登记业务准备，尚无媒体 |
| connecting | 已登记且通过本地协议工厂，等待媒体传输 |
| configuring | 已取得有效信令答案且传输通道可用，等待协议确认/音轨挂载 |
| active | 协议确认原配置所对应通道且activate完成；只表示本地媒体就绪 |
| localClosed | 本地停止；服务端占用和供应商终止另看证据 |

传输回调不是最终话语。协议适配器收到原练习配置快照，仅由其解析供应商事件并确认配置；任意JSON、通道开放、SDP或播放观察均不能直接触发active。实际供应商协议尚未实现，不存在运行时测试适配器。

传输ready前缓冲最多8个开放通道、32条/128KiB事件；单条最多64KiB。ready后先通知开放通道，再顺序交付缓存事件。发送与确认都限定已知通道；回调受同一控制器、账号、前台和单调截止保护。停止清空缓存，不存储原始JSON/SDP，不输出SDK异常。

## 租约、播放与失败

连接创建请求起点加服务端租约跨度形成保守本地截止。15秒只发一条续租，旧截止在HTTP等待期间继续有效；请求前、成功响应后和所有媒体回调前都核对，事件循环延迟不能让超期响应续命。允许同一身份/代次/配置的preparing、negotiating、configuring、ready；答案已取得后不能接受preparing降级。unknown/终态、账号或配置变化、网络失败即停止媒体。

连接建立总等待60秒，传输ready后的配置/激活总等待20秒。两阶段均保存单调截止，异步结果、发送/确认、媒体回调和激活前后复核；晚到结果不能抢在延迟的Timer前进入下一阶段。它们与45秒业务租约相互独立，不代表上游TTL、可信终止或费用封顶。

setMuted只响应用户明确操作；播放事件不改变上行静音。播放状态独立为idle/waiting/blocked/playing/paused，显式resumePlayback允许恢复浏览器播放限制，不能用active冒充声音已实际播放。

## 释放证据

stop同步封闭回调、停止传输、取消独立信令、释放协议与定时器，立即完成begin等待；API清理不阻塞本地释放。后台、账号作用域变化、销毁、传输local_closed、协议/续租错误及超时都走同一停止入口。回前台不自动开始。账号已变化时不在新身份下发送旧对象清理。

释放状态独立为notNeeded、pending、released、unconfirmed，仅描述本次登记的服务端清理证据。未调用exchangeOffer时，按连接→练习安全取消，只有not_started+结束时间及父cancelled都确认后才发布released；到期冲突可先读取服务端终态。创建/取消结果未知保持unconfirmed，不换key盲目再建。

调用exchangeOffer前先置signallingAttempted；之后所有停止都保持unconfirmed，不使用准备取消推断媒体终止，不自动重复offer。即使本地HTTP已取消，上游也可能已分配会话。停止后的在途业务续租可能先在服务端提交，但晚到结果不能恢复本地媒体，最终占用仍按服务端租约/可信终止处理。

connection属性保留最近一次业务HTTP快照，信令后在下次读取/续租前可能仍显示preparing；不能以旧快照的canCancel覆盖signallingAttempted或将其视为当前服务器状态。

验证见[本轮记录](../development/2026-10-17-practice-media-coordinator-verification.md)。持久观测、供应商协议、可信终止、转写/用量、跨进程恢复和页面均未实现；本轮不把端口和替身结果称为真实语音闭环。
