# 客户端媒体业务协调契约

日期：2026-10-17。实现独立的一次性PracticeMediaController，组合真实业务HTTP仓库、ApiRealtimeSignaller和现有RealtimeTransport端口。运行时协议工厂和后端准入均默认关闭；provider尚未被页面消费，成功配置/媒体路径只由明确替身验证。

2026-10-21实现更新：正常`end`已有固定截止的受限draining，异常stop/dispose保留立即释放；按[收尾契约](2026-10-20-practice-completion-and-review-contract.md#2-正常结束与立即释放)实施，详见[本批设计](../superpowers/specs/2026-10-20-bounded-media-drain-design.md)。归一化协议和设备输出仍为替身，不代表供应商正常结束、自然插话或可信终止已接通；最终文字追加/确认另见[文字契约](2026-10-20-final-transcript-storage.md)。

同日已接入[独立播放证据持久账本](2026-10-21-playback-evidence.md)：仅采集投影已接受的版本对齐、首次冻结快照与撤销，原账号/连接/epoch独立确认和只读分页重建。source仍为client_reported，未封存记录不赋予恢复或反馈资格。

同日后续已将正常end接入[服务端固定补交与输入固化](2026-10-21-practice-finalization.md)：原账号结束意图、drain后不可变清单、只读封存摘要与实收receipt共同收敛。只在正常end后触发产品结束，普通异常stop仍保持中断语义；没有新增正式页面，最终实测范围见[固化验证报告](../development/2026-10-21-practice-finalization-verification.md)。

## 入口与责任

| 文件 | 职责 |
| --- | --- |
| practice_media_controller.dart | 单次准备、媒体/协议回调、账号/前台检查、续租结果、同步停止和释放证据 |
| connection_lease_watchdog.dart | 单调时钟、保守原截止、续租与截止定时器 |
| realtime_session_protocol.dart | 供应商协议端口和受保护send/confirmConfigured/fail回调；实际默认Unavailable |
| practice_media_providers.dart | 随signedIn账号创建/销毁作用域，读取不自动登记或申请媒体 |
| connection_observation_journal.dart | 2026-10-18新增；原账号/连接/代次绑定的受限媒体观测队列与独立HTTP确认 |
| ../conversation/conversation_models.dart / conversation_projection.dart | 2026-10-18新增；原账号/连接作用域的有界文字/播放投影，归一化回调消费，不向观测journal写正文 |
| ../conversation/playback_evidence_models.dart / playback_evidence_journal.dart / playback_evidence_read_models.dart | 2026-10-21新增；自含来源版本的播放/首次freeze/revoke、原账号确认队列及支持服务器单向seal的严格分页重建 |
| ../practice/submission_manifest.dart / practice_completion_models.dart / practice_completion_client.dart | 正常end固定无正文清单、严格摘要/实收凭据、账号隔离HTTP及封存收敛；不控制媒体或终止权限 |
| core/random_uuid.dart | 原准备与新媒体控制器共用的安全随机v4 UUID |

原PracticePreparationController继续只管理信令前流程，不传递在途租约给新控制器。每个媒体控制器保存自己的clientInstanceId、practiceKey、connectionKey，直接调用已有登记契约；业务后端仍强制单用户占用，不能因为本地有两个provider就并行建连。

后续新增`callbacks.emitConversation(update, channelId)`：只在传输可用、配置已确认的同一通道消费归一化事实，允许activate等待期间接收。投影不把生成完成或播放观察当作已播放文本；conversation getter绑定账号，正常stop封存，账号变化/销毁清空。冲突/容量失败关闭本地媒体并保留已接受内容，默认协议/准入仍关闭。详见[对话投影契约](2026-10-18-conversation-projection.md)，不等于供应商事件、持久最终文字或自然打断已接通。

`begin(difficulty: ...)`只启动一次；重复调用共享等待，完成于本地active或localClosed。没有自动重试、恢复或重连；原key仅在当前实例内存保留，跨进程未知请求恢复另行实现。默认503直接结束，不构造协议、信令或媒体。

## 准备与就绪

顺序是练习created→连接preparing/not_started→保守租约→本地协议工厂→独立HTTP signaller→传输start。等待任意一步时停止，晚到结果只能安全清理，不能继续后面的媒体流程。协议/信令/传输工厂内同步停止时，刚返回的对象也会释放。

| 本地状态 | 依据 |
| --- | --- |
| preparing | 正在登记业务准备，尚无媒体 |
| connecting | 已登记且通过本地协议工厂，等待媒体传输 |
| configuring | 已取得有效信令答案且传输通道可用，等待协议确认/音轨挂载 |
| active | 协议确认原配置所对应通道且activate完成；只表示本地媒体就绪 |
| draining | 同步停采停播，冻结原话轮/response，仅在固定窗口内接收原确认通道的收尾事实 |
| localClosed | 本地停止；服务端占用和供应商终止另看证据 |

传输回调不是最终话语。协议适配器收到原练习配置快照，仅由其解析供应商事件并确认配置；任意JSON、通道开放、SDP或播放观察均不能直接触发active。实际供应商协议尚未实现，不存在运行时测试适配器。

传输ready前缓冲最多8个开放通道、32条/128KiB事件；单条最多64KiB。ready后先通知开放通道，再顺序交付缓存事件。发送与确认都限定已知通道；回调受同一控制器、账号、前台和单调截止保护。停止清空缓存，不存储原始JSON/SDP，不输出SDK异常。

## 租约、播放与失败

连接创建请求起点加服务端租约跨度形成保守本地截止。15秒只发一条续租，旧截止在HTTP等待期间继续有效；请求前、成功响应后和所有媒体回调前都核对，事件循环延迟不能让超期响应续命。允许同一身份/代次/配置的preparing、negotiating、configuring、ready；答案已取得后不能接受preparing降级。unknown/终态、账号或配置变化、网络失败即停止媒体。

连接建立总等待60秒，传输ready后的配置/激活总等待20秒。两阶段均保存单调截止，异步结果、发送/确认、媒体回调和激活前后复核；晚到结果不能抢在延迟的Timer前进入下一阶段。它们与45秒业务租约相互独立，不代表上游TTL、可信终止或费用封顶。

setMuted只响应用户明确操作；播放事件不改变上行静音。播放状态独立为idle/waiting/blocked/playing/paused，显式resumePlayback允许恢复浏览器播放限制，不能用active冒充声音已实际播放。

## 释放证据

stop同步封闭回调、停止传输、取消独立信令、释放协议与定时器，立即完成begin等待；API清理不阻塞本地释放。后台、账号作用域变化、销毁、传输local_closed、协议/续租错误及超时都走同一停止入口。回前台不自动开始。账号已变化时不在新身份下发送旧对象清理。

正常`end`独立于stop：首次动作冻结原scope/话轮/response，安排只异步执行的服务端结束意图，Web beginDrain同步停采停播，只保留原确认通道；默认3秒，可配1–5秒，取当时租约更早截止，停续租且忽略在途续租的成功/失败结果。每次回调复核截止，重复end共享Future。只有冻结话轮的final/修订和相应播放证据可进入；TurnStartedUpdate使没有字幕的已发输入也能收尾。协议beginDrain只调用一次，输入完成/原response取消控制分别去重；普通send被关闭。同步返回的收尾事实先经32条/128KiB有界队列暂存，完成输出冻结后依序验证。没有可核验完成信号时不提前判齐，到期为tail_unconfirmed；结束意图或HTTP等待不延长媒体截止，drain抛错仍保留服务端意图，提前异常关闭申报aborted。

关闭前保留快照，采集所有!isFinal话轮（含空文字已发输入）、无可靠输出依据的response及两journal缺口；finish后固定全部已接纳事件的ID/sequence/预算清单一次，包含已ACK及pending。journal不可用时明确journal_unavailable，不把空清单冒充完整。completion先end再manifest串行，稳定key/body、8秒总截止包含CSRF；失败暂停显式retry，refresh只读，不隐式重试失败写。manifest已接受或封存后只读有界等待，每轮最多20次/40秒，超限保留待核对状态；不改变releaseStatus或建连许可。

summary sealed后还须读取原scope及匹配全局hash的receipt，再交两journal按实收refs收敛。已收到而丢ACK的项可确认，未收到的pending记永久未保存并暴露sealed_unsaved，取消在途/忽略晚ACK、停止重试并清正文，不假报ACK或普通拒收。provider在draining、任一队列pending、completion待确认/失败或receipt收敛期间保留原账号作用域；都已收敛后允许无人监听释放。正常end后的同账号离页不取消，身份变化/销毁立即abort。未发正常end的background/page_left/协议错误继续旧中断/安全准备清理，不擅自调用产品结束。

自然中断的归一化freezeResponse固定设备输出上限和原截止，封存独立版本前缀；普通生成及新response须等prepareContext产生的原scope不可变token，经一次sendContextControl及同token/当前revision/原通道的供应商截断确认后才允许。用户输入仍可接收，旧AI的合法final/播放证据在原窗口内继续保存，不回写已确认token。明确推翻已用前缀时先撤销当前资格，再安全stop(context_invalidated)。这些是本地协议门；真实上游截断及旧音频路由仍须供应商准入实测。

播放journal在原连接登记成功后创建，普通生成不入队，只有applied播放更新采集完整原turn；首次freeze保存停止前的来源版本，重复freeze不新增。控制器保留每response已接受播放位置的历史最大值，正常end的保守冻结边界不会因新final重置unknown而退回。已应用revoke先入队，再因上下文失效安全停止。stop对两种正文journal分别finish，身份变化/销毁abort；保存错误、拒收及永久未保存计数可见，不阻塞媒体释放。读取provider和原连接GET均不启动媒体，正文队列与completion留存/释放按前述独立条件执行。

释放状态独立为notNeeded、pending、released、unconfirmed，仅描述本次登记的服务端清理证据。未调用exchangeOffer时，按连接→练习安全取消，只有not_started+结束时间及父cancelled都确认后才发布released；到期冲突可先读取服务端终态。创建/取消结果未知保持unconfirmed，不换key盲目再建。

调用exchangeOffer前先置signallingAttempted；之后所有停止都保持unconfirmed，不使用准备取消推断媒体终止，不自动重复offer。即使本地HTTP已取消，上游也可能已分配会话。停止后的在途业务续租可能先在服务端提交，但晚到结果不能恢复本地媒体，最终占用仍按服务端租约/可信终止处理。

connection属性保留最近一次业务HTTP快照，信令后在下次读取/续租前可能仍显示preparing；不能以旧快照的canCancel覆盖signallingAttempted或将其视为当前服务器状态。

2026-10-18已接入可选journal工厂：登记成功后才创建，传输、配置确认、激活、播放及显式静音分别记录client_observed事实；停止先释放媒体，再记录一次local_closed并finish，账号已变则abort。工厂和上报错误只影响观测错误/队列，不阻塞媒体安全清理。默认503不创建journal；构造provider仍无API或媒体副作用。后端持久化及只读分页均不改变连接/租约/终止，不能用客户端关闭事实释放unknown。详见[观测契约](2026-10-18-connection-observations-api.md)。

原协调验证见[记录](../development/2026-10-17-practice-media-coordinator-verification.md)，新增组合证据见[观测验证](../development/2026-10-18-connection-observations-verification.md)及[持久播放验证](../development/2026-10-21-playback-evidence-verification.md)，本批固化接入证据由新验证报告记录。偏好页[只读恢复查看](2026-10-18-readonly-recovery-client.md)不控制此协调器。供应商收尾/配置/对齐协议、可信终止执行器、完整反馈资格与任务、用量、跨进程媒体/上下文恢复和正式练习页仍缺；blocked核验意图和输入固化不构成真实语音闭环。
