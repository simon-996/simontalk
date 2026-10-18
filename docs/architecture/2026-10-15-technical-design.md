# SimonTalk 技术设计

日期：2026-10-15。本文定义技术方案与约束，选型状态逐项列明；实施进度和验证证据由根目录 [HANDOFF.md](../../HANDOFF.md) 及相应验证报告维护。

## 1. 已确认范围与待决策项

已确认的产品约束：面向中国大陆；本人和少量受邀朋友各自独立练习；Flutter 覆盖 iOS、Android、Web；练习英语日常交流；自动接话和无需点击的自然插话；每人独立难度；会后集中反馈；轻量语音伙伴界面。这里的邀请是加入产品，各人的对话、设置和记录不共享；首版没有多人语音房。

| 项目 | 当前状态 | 本文处理方式 |
| --- | --- | --- |
| Flutter / Dart、三端产品范围 | 已确认 | 作为设计约束 |
| Riverpod、go_router | 工程采用 | 负责客户端状态和导航，具体版本见锁文件 |
| Python、FastAPI、Pydantic | 工程采用 | 一个业务后端，按模块划分代码，不拆微服务 |
| PostgreSQL、SQLAlchemy、Alembic | 工程采用 | 当前账号与偏好已实现，持久任务仍待对应功能 |
| 邀请码加用户名/密码 | 工程采用 | 已落实首批账号基础，具体行为见账号契约 |
| 仅保存文字及反馈、删除关联重练 | 数据策略建议，未单独确认 | 需与主产品文档一同评审 |
| 千问北京地域 WebRTC + flutter_webrtc | 首轮技术候选 | 不表示三端已经可用、体验达标或预算可控 |
| 前台练习，进入后台或锁屏暂停拾音 | 产品与技术建议，未确认 | 返回后新建连接并显式恢复上下文 |

本文提出工程边界和文字形式的接口契约，不生成 API schema 或实现代码。产品范围以[首版设计](../superpowers/specs/2026-10-15-simontalk-mvp-design.md)为索引，选型证据见[调研记录](../research/2026-10-15-product-and-stack-review.md)。质量阈值、测试网络和真机矩阵统一由[验证计划](../validation/2026-10-15-validation-plan.md)维护，本文不重复承诺延迟或成功率。

2026-10-16 实施更新：账号与偏好的工程基线见[基础决策](2026-10-15-foundation-decisions.md)，当前可调用接口以[账号契约](2026-10-15-account-api.md)为准。本文其他模块仍是后续设计，不表示已实现。

以下是本项目自有系统的**可审议默认值**，尚未经用户批准，也不是外部政策或供应商承诺。它们使文档具备明确的初始参数，评审后可一起调整。

| 参数 | 建议默认 | 计算与清理边界 |
| --- | --- | --- |
| 登录会话 | 签发起固定 7 天，可提前撤销 | 不因活跃访问自动延长；到期重新登录 |
| 邀请码 | 签发起 72 小时，仅一次注册 | 消耗、过期或撤销后失效 |
| 密码重设凭证 | 签发起 15 分钟，仅使用一次 | 成功重置时原子消耗，并撤销全部登录会话 |
| 用户最终文字和反馈 | 保留至用户删除 | 删除范围包括主练习及其派生重练，见第 12 节 |
| 业务数据库备份 | 保留 7 天 | 超窗备份过期；恢复后重放最新删除清单 |
| 删除清单 | 删除请求起保留 14 天 | 只含目标 ID、时间及清理状态，不含原话；与旧数据库快照分开保留 |
| 最小用量账本 | 调用发生起保留 90 天 | 不含用户原话；删除练习不返还已发生额度 |
| 移动端未确认文字 outbox | 首次入队起最长 24 小时 | 保护存储、确认即删、到期即删、退出账号清空；重试不顺延期限 |
| Web 未确认文字 | 仅当前页面内存 | 不持久化；刷新或关闭后只能恢复服务器已确认内容 |

## 2. 单仓库与模块边界

项目采用 GitHub 单仓库 [simon-996/simontalk](https://github.com/simon-996/simontalk)，统一管理 Flutter 客户端、一个业务后端、文档及部署配置。目录约定为 apps/client/、services/api/、docs/ 和 deploy/，应用目录在进入相应开发阶段时创建。客户端与后端可以独立构建、部署和发布；同仓库不要求同一次发布。

首版部署仅需 HTTPS 反向代理、Flutter Web 静态产物、业务后端、PostgreSQL；使用 Docker Compose 是建议。持久任务处理器随同一个后端进程启动，使用数据库协调；不另建第二套业务服务。

| 模块 | 负责 | 边界 |
| --- | --- | --- |
| Account | 邀请、注册、登录、会话凭证、账号禁用 | 不向普通用户暴露他人身份或学习数据 |
| Preferences / Topics | 独立难度、语速、字幕、中文提示与按需翻译偏好、日常话题 | 显示控制可立即生效；难度等生成策略用于新练习，历史保留原快照 |
| Practice | 逻辑练习、连接尝试、开始/结束、原练习与重练关系 | 一个练习可包含多次媒体连接，但同一时刻只允许一个有效连接代次 |
| Realtime Adapter | WebRTC、设备音频、模型事件映射、打断及释放 | Flutter 页面不解析供应商事件；后端不假装已经掌控直连媒体 |
| Transcript | 最终话语、播放状态、版本、水位、幂等确认 | 临时字幕不是历史；生成完毕不等于已经播放 |
| Assistance | 按需英文开头和单句中文翻译 | 文字辅助与真实话语分开，不自动朗读，不写成用户已说内容 |
| Review | 固化反馈输入、生成任务、结构化反馈、重试 | 只引用实际用户话语，不伪造发音分数 |
| History / Deletion | 本人列表、详情、删除与关联清理 | 所有查询、写入及关联均检查所有者 |
| Usage / Operations | 准入、并发、用量来源、任务租约、诊断 | 客户端计时只是观测，不能单独充当强制限额 |

客户端页面依赖用例和领域状态；领域状态依赖账户、练习仓储及统一的 RealtimeSession；平台音频与供应商实现放在适配层。后端按 HTTP 接口、用例、供应商网关、数据仓储分层；单独封装实时供应商和反馈文本模型，二者无需使用同一家厂商。

偏好字段与交互分开处理：subtitle_default 是新页面的字幕默认值，当前通话内的显示/隐藏可立即切换；chinese_hints_enabled 控制中文提示显示，当前页面可立即生效；translation_mode 首版仅允许 on_demand，用户主动请求时才展示或生成翻译，不自动翻译整段历史。显示开关本身不触发额外模型调用。difficulty、speech_pace 等影响模型生成的设置保存后用于新练习快照，首版不承诺在旧连接中热更新；任何偏好修改均不改写历史会话快照或原转写。

通话按钮“说慢一点”属于用户对当次对话的明确请求，与修改个人 speech_pace 默认值分开。适配器应把它作为有来源标记的控制请求，影响后续新回复，不自动重播旧句，也不冒充用户实际说过的话。具体通过受支持的会话控制或文字请求实现，必须纳入候选模型验证；只有收到可验证的接受结果才显示请求已发送，能力缺失或失败时给出说明，并允许用户直接用语音提出请求。它不改变本场最初配置快照，另记控制事件。

“给我一个英文开头”和逐句翻译建议由业务后端单独调用文本模型，结果仅作为辅助文字。请求绑定本人的练习、已确认的上下文版本或具体话轮；不传任意他人的原话，不把临时字幕作为确定输入。显示开关、展开已有结果不重复调用；新的主动生成按独立用量计入。提示结果不自动注入实时媒体上下文，也不参加用户能力评价。

首版不需要 Redis、向量数据库、Kubernetes、多代理、分布式事件总线或微服务。学习者个性化先使用明确的偏好字段和当次上下文，不把长期记忆系统作为开口练习的前置条件。

## 3. 媒体流与业务流

### 3.1 两条独立路径

**业务路径：** Flutter → 同源 HTTPS 业务 API → 账号/练习/转写/反馈/用量 → PostgreSQL；业务后端 → 供应商鉴权和文本反馈 API。

**首轮候选媒体路径：** Flutter 麦克风 ↔ WebRTC 媒体轨道 ↔ 千问实时模型；模型事件通过 DataChannel ↔ Flutter 适配器。最终文字和连接观测另外提交业务后端。业务后端代理 SDP，不承接这条路径上的每一个音频包。

阿里云文档明确区分 WebRTC 媒体轨道与 DataChannel，并要求 AppServer 参与 SDP 鉴权；它不提供专用 WebRTC SDK。[官方 WebRTC 接入说明](https://help.aliyun.com/zh/model-studio/realtime-webrtc-access)与 [flutter_webrtc 包说明](https://pub.dev/packages/flutter_webrtc)分别证明接口和组件能力，不能代替这两者在本项目三端上的集成验证。

2026-10-18工程进展：当前Web优先阶段使用浏览器原生RTCPeerConnection和Dart JS interop，暂不增加原生依赖。已实现供应商无关的`RealtimeTransport`、后端[连接登记/代次与租约](2026-10-17-connection-reservations-api.md)、[受限单次信令](2026-10-17-guarded-signalling-api.md)、独立[媒体业务协调器](2026-10-17-practice-media-coordinator.md)及[受限持久观测](2026-10-18-connection-observations-api.md)。信令先持久unknown意图再调用网关；协调器组合准备、信令、续租、配置确认门槛、本地释放和有界观测journal。实际准入、网关与客户端协议工厂均固定关闭，成功媒体状态只用替身验证，没有正式练习页面或供应商调用。底层`start`仅表示传输及通道可用，协议确认后`activate`；激活与播放观察独立，`local_closed`不代表上游终止。完整领域话语/响应/播放上下文、供应商协议/网关、媒体恢复和可信终止仍待实现，不能把底层直接接到页面当成真实练习。[底层设计](../superpowers/specs/2026-10-17-web-realtime-transport-design.md)与[验证边界](../development/2026-10-17-web-realtime-transport-verification.md)。

### 3.2 开始一次练习

1. 客户端说明麦克风用途，用户点击开始；申请权限并处理 Web 自动播放限制。尚未就绪时界面显示连接中，不显示正在听。
2. 后端从已认证身份读取偏好，校验话题、单用户并发和当前准入额度，创建逻辑练习并保存配置快照。客户端不能指定任意 owner_id。
3. 后端创建连接尝试，分配 connection_id、递增的 connection_epoch 和服务端选择的供应商/模型配置。相同幂等请求返回同一尝试。
4. 客户端创建 PeerConnection，注册本地与服务端创建的 DataChannel、媒体及状态回调；协商双向音频，准备但暂不上送真实麦克风轨道。
5. 客户端将 Offer SDP 发给业务后端。后端检查练习所有权、连接代次和有效期，再向固定白名单端点附加长期 API Key 交换 SDP，只返回 Answer SDP。
6. 客户端分别等待传输连接、事件通道及目标模型配置确认。对要求 session.updated 的模型，只有该确认到达后才挂载上行轨道。SDP 交换成功不代表全部条件已满足。[官方初始化时序](https://help.aliyun.com/zh/model-studio/realtime-webrtc-access)
7. 进入 active；在 AI 播放时仍保持用户上行，支持自然插话。静音是用户主动关闭上行，不借“AI 正在说话”自动禁用麦克风。

候选模型、地域、声音、轮次策略、提示词版本和适配器版本由后端配置并保存快照。难度主要影响词汇、句长、辅助方式和等待策略；不把一个提示词或静音阈值等同于稳定的难度适配。

### 3.3 SDP 代理的安全边界

三端统一经过本项目 SDP 代理；不把供应商长期密钥放入 Dart define、App 包、网页、日志或客户端数据库。当前千问文档中的 WebRTC 鉴权发生在 SDP HTTP 请求；不能把其他厂商的短期密钥机制直接套用过来。[Token 鉴权](https://help.aliyun.com/zh/model-studio/realtime-token-authentication)

代理只接受本服务已创建的连接，固定上游地域、业务空间、模型和请求方法；不接受客户端提供任意目标 URL、Authorization 或账单配置。限制请求大小、总时长和重复并发；SDP 可能含网络地址，不写入常规日志或长期数据库。建连超时后，上游是否已分配付费会话可能未知，应记录 unknown 并尝试关闭，不能无条件循环建立新会话。

直连 DataChannel 由客户端持有；如果供应商允许客户端改写会话设置，业务后端生成过提示词并不代表这些约束不可绕过。模型白名单、最大时长和额度若要成为硬约束，必须有供应商服务端控制或服务端持有上游连接的证据。

## 4. 统一 RealtimeSession 契约

以下是待实现的领域接口说明，不是某厂商已经支持的能力清单。适配器必须声明能力、映射来源和限制；不支持的操作明确返回 unsupported，不静默假装成功。

| 操作 | 责任与结果 |
| --- | --- |
| prepare / connect | 准备设备、交换 SDP、初始化模型；只有全部就绪才发出 ready |
| setMicrophoneEnabled | 设置上行音轨；返回实际状态和设备错误 |
| requestSlowerSpeech | 提交当前对话的明确语速请求，返回接受、失败或 unsupported；不修改个人默认值，不生成用户语音转写 |
| interrupt | 指向当前 response_id，停止本地旧播放、取消上游生成、处理旧上下文；分别报告确认状态 |
| restoreContext | 向新供应商连接装载本次练习已确认文本；不是恢复旧供应商会话 |
| end / dispose | 停止采集、取消旧回复、关闭通道/连接/播放器；幂等，拒绝随后到达的旧回调 |

每个事件包含 practice_session_id、connection_id、connection_epoch、本地 event_id、单连接递增 sequence、发生时间和接收时间；话语相关事件附 turn_id，AI 事件附 response_id 和可用的 provider_item_id。供应商的事件编号只在适配器内映射，不作为全局唯一业务编号。

| 统一事件 | 语义 |
| --- | --- |
| transport.changed / session.ready / session.closed | 传输、模型就绪与关闭；ready 与 transport.connected 分开 |
| input.speech.started / stopped | 轮次与打断候选，不能当作最终 ASR 文本 |
| input.transcript.delta / final | 临时字幕/最终用户话语；final 仍按版本接受合法修订 |
| response.started / generation.finished | AI 回复开始/生成结束；不代表设备播放完成 |
| output.transcript.delta / final | AI 已生成文本，尚不能全部作为用户已听上下文 |
| playback.progress / finished | 播放至设备的进度和完成依据，附精度/来源；无法观测时标 unknown |
| interruption.requested / confirmed | 本地停止、生成取消、上下文截断分别有状态，不能以其中一个代替全部 |
| usage.observed | 附 source 和单位；客户端转发的供应商事件仍属于 client_reported |
| recoverable.error / fatal.error | 稳定业务错误码、是否可重试、脱敏诊断 ID |

能力至少区分：持续双向音频、声学/语义轮次、自然插话、显式取消、清空输出、上下文截断/删除重建、播放进度精度、最终用户转写、AI 音频对齐、服务端终止、可信 TTL、用量回调、供应商原生 resume。初始状态全部为未验证；传输能力不能替代模型控制能力。

## 5. 会话状态、话语与自然插话

### 5.1 状态分开管理

| 层 | 状态与规则 |
| --- | --- |
| 业务练习 | created → connecting → active；异常进入 interrupted；结束进入 ending，随后 completed；无有效内容可 cancelled，无法完成可 failed |
| 单次媒体连接 | preparing → negotiating → configuring → ready → closing → closed；失败为 failed，失去可信状态为 unknown |
| UI 交互 | 用户说话、AI 生成、AI 播放、静音、断线等并行标志，不用一个互斥的“听/想/说”枚举禁止同时收发 |
| 反馈任务 | pending / running / retry_wait / succeeded / failed / cancelled；独立于练习完成状态 |

服务端根据事件推进持久业务状态，但直连媒体状态主要来自客户端观测，应保留来源。业务后端失联时，客户端建议暂停拾音并主动关闭媒体；这是降低意外消耗的客户端行为，不能证明服务器已经终止上游计费。

当前业务连接登记分配服务端单调epoch并保存公开配置；45秒业务租约到期时，只有preparing/not_started能安全终结，已进入或无法确认上游的状态转unknown并继续占用。扫描器有CLI及正常API lifespan内每15秒有界周期调度，并清理闲置300秒且从未调用上游的created准备；保留原行和幂等键，不终止媒体或结算费用。只读current查询可恢复本人当前占用，异常父终态仍优先保留未知连接。当前新登记真实准入仍固定503，其他媒体状态仅有未来集成契约及明确测试种子。[连接约束](2026-10-17-connection-reservations-api.md)与[恢复/调度](2026-10-17-preparation-recovery-and-cleanup.md)。

客户端信令前准备生命周期已实现：固定账号的HTTP仓库、两个原始创建键、单调时间保守截止、15秒串行续租和后台安全取消。停止后的明确重试只恢复曾发送的未知登记并清理，不推进新连接。独立媒体控制器另已组合WebRTC和配置确认端口；真实协议尚未实现，账号作用域provider尚未由页面消费。[准备契约](2026-10-17-client-preparation-lifecycle.md)与[媒体契约](2026-10-17-practice-media-coordinator.md)。

受限观测已按原连接/客户端/epoch持久化，来源固定client_observed；历史或unknown可接收迟到事实，但不能改变练习/连接状态、租约、终止或占用。客户端仅用有界内存journal，稳定事件ID/序号、串行确认、显式重试、账号隔离；停止先释放媒体，上报失败不阻塞。记录可能有缺口，不包含话语、音频或用量。偏好页已提供current及原连接分页的[只读恢复入口](2026-10-18-readonly-recovery-client.md)，明确点击才查询，不恢复媒体或接管连接。当前配置确认也只是客户端观测，不将其升级为服务端ready或可信上游证据。[观测契约](2026-10-18-connection-observations-api.md)。

偏好页另提供[未开始准备的明确清理](2026-10-18-preparation-discard-api.md)：弹窗捕获原快照，确认后POST expected_epoch；服务端锁后核对完整代次历史全部未调用上游，原子关闭最新preparing并取消父行。unknown、历史信令或缺行均拒绝；不删除历史，不采纳他人租约。成功仅确认原准备，需刷新查看当前状态；超时不自动重试。同一账号HTTP家族共享CSRF签发状态，保持独立取消。

### 5.2 用户轮次和 AI 已播放文字

VAD 起止、ASR 最终文本和 AI 回复可能乱序到达。适配器使用供应商 item/response 标识关联，不以消息抵达顺序拼接成新话语。一个用户轮次可有临时结果和多次 final 修订；只有最终文本进入历史。无识别结果的轮次记录状态，不编造用户原话。

AI 的 generated_text 与 played_text 分开：前者是模型完成的转写，后者是有播放证据的前缀。delivery_status 为 played、partial、not_played 或 unknown；另存 played_until_ms 与依据/精度。所谓“已播放”指已交付设备输出，不能证明用户确实听见或理解。

response.done 或音频生成完成不等于扬声器缓冲已播放完成。没有可靠字词/音频对齐时，不按字符比例从毫秒数推算“精确听到的句子”。打断后的未知后缀在历史中标明，反馈和重建上下文不将其作为已交流的事实；客户端可展示带“未播完”标记的生成文本。

### 5.3 打断必须同时解决三件事

1. **本地停播：** 确认用户开始说话或点击“我来说”后，停止当前输出并清空可控制的队列，提升播放代次；丢弃旧 response 的后续字幕和音频。持续监听上行，并处理外放回声，不能靠轮流静音伪装全双工。
2. **取消生成：** 对当前 response_id 发送供应商支持的取消操作；自动取消和手动取消重复发生时仍幂等。等待确认或超时，记录实际结果，不把本地静音当作取消成功。
3. **修正上下文：** 将旧 AI 回复截断至有证据的播放边界；若模型仅支持删除/重建，则删除整条并只补回可确认前缀。若无法可靠调整旧连接，结束它并以确认文本创建新连接；只有该替代行为通过验证，才可接受为候选实现。

RTP 音频不像逐帧应用消息那样必然带 response_id；仅 mute 后立刻 unmute 可能播出旧抖动缓冲。适配器需验证供应商清空输出、取消确认和远端音轨的实际行为；若无法区分残留旧音频与新回复，不得宣称打断完成。

千问不同模型的事件、轮次和取消能力需分别验证；不能从 WebSocket 示例推定所有 WebRTC 模型都具有精确截断或播放进度。[模型协议边界](https://help.aliyun.com/zh/model-studio/realtime-webrtc-access)及 [Qwen-Audio 交互说明](https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides)作为候选评估依据。

### 5.4 结束与转写固化

点击结束先停止上行，并按打断规则处置尚未播完的 AI 回复；随后关闭媒体。客户端把尚未确认的最终话语写入本地待提交队列，提交各连接的最后事件/转写水位，再请求结束。后端先事务性保存 ending 及持久 finalize 任务，返回可查询的状态；不等待反馈模型返回才确认结束。

finalize 任务等待约定的最终提交窗口或明确水位，固化 transcript_revision 和 transcript_hash，再在同一事务中创建唯一反馈任务。窗口届满仍缺少内容时标 transcript_incomplete；保留记录并说明反馈依据不足，不杜撰缺失部分。会话封存后的新修订不静默改写已有反馈；若需接纳，显式形成新 revision 并使旧反馈失效。

## 6. 断线、离开页面和恢复

区分短暂 ICE 抖动、DataChannel 关闭、模型错误、业务 API 不可用和整个 App 重启。只有供应商文档与验证明确支持同一会话恢复时，才使用其原生 resume；不假定 ICE restart、重新交换 SDP、跨模型或跨供应商连接能延续原来上下文。

建议首版恢复方式：停止旧采集与播放 → 关闭旧连接并记录终止结果 → 向业务后端获取最新有效连接代次和确认话语 → 新建媒体连接 → 明确提示“已重新连接，继续刚才的话题” → 注入难度/话题快照及有限的已确认文本。重建内容只含用户最终话语和可确认的 AI 已播放部分；没有原始音频可重传，也不自动重播最后一句。

后端仍使用同一逻辑练习 ID，连接代次递增，拒绝旧连接的状态推进和晚到话语污染；旧转写补交走受限的结算窗口。无法确认旧上游已关闭时，标 orphaned/unknown 并执行清理；若可能产生并行付费且无上游控制，不自动发起多次连接。

App 进入后台、锁屏或用户离开通话页时，建议暂停并停止拾音；再次进入显式新建连接。Web pagehide、App 生命周期回调及网络通知均是尽力而为，不能依赖它们必定执行。服务端根据持久连接租约和失联扫描收拢业务记录；失联收拢不等于远端媒体已被服务端强制终止。

客户端仅为提交可靠性暂存当前用户未确认的最终文字及必要 ID，不缓存音频、凭证或全部历史。移动端建议使用保护的文字 outbox，例如由系统安全存储管理密钥的加密存储；首次入队起最长保留 24 小时，服务器确认、到期或退出账号时删除，重试不顺延期限。重开 App 时先核对账号和会话状态，跨账号不得补交；存储实现仍需平台验证。

Web 首版只把未确认文字放在当前页面内存，不写 localStorage、IndexedDB 或其他持久缓存。刷新、关闭页面或浏览器回收页面后，这部分可能丢失；只恢复服务端已经确认的文字，并如实标记不完整记录。不能承诺浏览器具有受保护的持久文字存储，也不能保证恢复未提交文字。这些都是可审议的数据策略默认。

## 7. 身份与数据隔离

### 7.1 认证建议

邀请码只用于一次注册资格，不用作长期登录凭证。建议签发起 72 小时有效且仅能注册一次。服务端存高熵邀请码的摘要、到期时间、撤销状态、最大次数和使用者；注册时在同一事务内消耗邀请并创建唯一用户名，防止并发重复使用。少量朋友由管理员生成邀请，不做公开自助注册或社交关系。

建议用户名与展示名分离，用户名做一致规范化和唯一约束；密码用维护良好的密码哈希库与 Argon2id，具体资源参数在实现前结合部署机器验证。登录/注册限速按 IP 和账号维度处理，错误不泄露账号是否存在；首版不依赖 Redis，可由反向代理及数据库中的有限计数实现。

建议使用可服务端撤销的随机 opaque session token：数据库只存 token 摘要；移动端以 Bearer 方式使用，并保存在 iOS Keychain / Android Keystore 支持的安全存储中；Web 使用 Secure、HttpOnly、SameSite Cookie。每次登录签发新会话，建议自签发起固定 7 天有效，不因访问而滚动续期；退出、账号禁用或密码重置可提前撤销。到期重新登录，不能在客户端把长期令牌放入普通 SharedPreferences 或 Web localStorage。这是可评审的本项目默认。

若采用用户名/密码，首版忘记密码入口仅提示“联系维护者”。维护者在线下核实身份后，通过受管理员认证保护的内部操作生成随机单次 PasswordResetGrant；建议签发起 15 分钟有效，仅交付一次原始凭证，服务端只存摘要。具体线下核实和交付方式由维护者与用户约定；本设计不假设已开通邮件、短信或其他通知渠道，也不自动发送通知。

用户持重设凭证自行填写新密码；维护者不代设、查看或接收新密码。确认接口从凭证确定目标账号，不接受任意 target_user_id。更新密码、消耗凭证、撤销该账号全部登录会话及其他未使用重设凭证在同一事务内完成；完成后要求重新登录。凭证不放入普通日志或 URL 查询参数；过期、已用或撤销均返回通用无效凭证错误，并对尝试限速。

Web 建议静态站与 API 同源。Cookie 会自动携带，因此状态变更接口采用 CSRF token 并校验 Origin，覆盖登录、退出、注册、SDP、结束、重试和删除。HttpOnly 不能替代 CSRF 防护；CORS 决定浏览器脚本能否读取跨源响应，也不是认证或 CSRF 防护。确需跨源时仅允许明确来源和 credentials，不使用通配符放行带凭证请求。移动端 Bearer 请求不依赖浏览器 Cookie，但仍执行身份和权限检查。

### 7.2 所有者规则

每次访问均从认证会话获取 user_id，按 user_id 与对象 ID 一起查询。随机 UUID 不能替代权限检查；不允许传入 owner_id 切换身份；他人对象统一按不存在处理。本人账号也不能把他人的 feedback_item_id、source_session_id 或 connection_id 作为自己的关联。

数据库为敏感子表保留 user_id，并对与 session_id 等父对象的组合关联施加同属用户约束；用例层再次检查。管理功能只处理邀请、账号状态、单次密码重设凭证与聚合用量，默认不提供浏览朋友转写的页面。日志和诊断不默认记录对话正文。

## 8. 建议数据实体与关系

以下字段是评审用逻辑模型；不是已创建的数据库表。时间统一存 UTC，前端按用户时区展示。状态字段与外键、唯一约束共同保证合法转换，不依靠页面约定。

| 实体 | 主要字段 | 关系与约束 |
| --- | --- | --- |
| User | id、username_normalized、display_name、password_hash、status、created_at | 用户名唯一；不保存明文密码 |
| Invite | id、token_hash、created_by、expires_at、max_uses、used_count、revoked_at | 推荐单次使用；注册事务内原子消耗 |
| AuthSession | id、user_id、token_hash、platform、created_at、expires_at、revoked_at、last_seen_at | 摘要唯一；固定有效期默认 7 天；退出、账号禁用或密码重置时撤销 |
| PasswordResetGrant | id、user_id、token_hash、issued_by、created_at、expires_at、consumed_at、revoked_at | 默认 15 分钟、单次使用；绑定用户；确认重置与会话撤销原子执行 |
| UserPreferences | user_id、difficulty、speech_pace、subtitle_default、chinese_hints_enabled、translation_mode、version | 每用户一条；translation_mode 首版仅 on_demand；显示控制可立即生效，难度/语速用于新练习；难度不伪称 CEFR 认证 |
| Topic | id、version、title、goal、starter、enabled | 首批少量静态配置也可；不必单独做内容后台 |
| PracticeSession | id、user_id、kind、status、topic_snapshot、preferences_snapshot、prompt_version、started_at、ended_at、end_reason、transcript_revision/hash、transcript_incomplete、source_session_id、source_feedback_item_id | 普通练习或逐句重练；来源必须同属用户；历史配置不可随偏好更新 |
| RealtimeConnection | id、session_id、user_id、epoch、provider、model、region、adapter_version、provider_session_id、status、last_seen_at、termination_status、provider_request_id | session_id + epoch 唯一；上游 ID/TTL 可为空，空值不表示可终止 |
| ConnectionObservation（已实现） | connection_id、client_instance_id、epoch、event_id、sequence、code、elapsed_ms、reason、event_digest、source、received_at | 原连接身份复合外键；event_id/sequence各自按连接唯一；source固定client_observed，无业务状态转移；每连接API最多256条 |
| Turn | id、session_id、user_id、connection_id、turn_index、role、provider_item_id、response_id、revision、text、played_text、delivery_status、played_until_ms、playback_evidence、finalized_at | session_id + id 唯一；用户话语不填播放字段；模型生成文本和可用上下文分开 |
| Feedback | id、session_id、user_id、transcript_revision/hash、prompt_version、model、status、next_step、created_at | 同一会话输入版本和提示词版本只有一份有效结果 |
| FeedbackItem | id、feedback_id、user_id、source_turn_id、original_quote、suggestion、explanation_zh、kind、uncertainty | 最多三项，引用须能在当前用户最终话语中定位 |
| AssistanceRequest | id、user_id、session_id、kind、source_turn_id、input_revision、status、result_text、created_at | english_starter / translation；翻译绑定本人练习中的可靠话轮，开头使用最少已确认上下文；随练习删除，不混入 Turn |
| DurableJob | id、user_id、session_id、kind、dedupe_key、state、attempts、next_attempt_at、lease_owner、lease_until、input_revision、result_id、last_error_code | finalize / feedback / assistance / 必要的清理；dedupe_key 唯一，不把内存任务当队列 |
| UsageRecord | id、user_id、session_id、connection_id、operation、source、provider_event_id、unit、quantity、observed_at、settled_at、estimated_cost、pricing_version | source 区分可信服务端结算与客户端观测；计费事件去重，不用二者相加 |
| IdempotencyRecord | user_id、operation、key、request_hash、resource_id、result_status、expires_at | 用户+操作+key 唯一；相同 key 不同请求体返回冲突 |
| DeletionRecord | id、user_id、target_session_ids、requested_at、expires_at、app_status、provider_cleanup_status、backup_expiry、error_code | 默认保留 14 天；目标 ID 供清理及备份恢复后重放删除；不保留被删对话正文 |

User → 多个 PracticeSession → 多个 RealtimeConnection / Turn；PracticeSession → Feedback → 多个 FeedbackItem。重练是新的 PracticeSession，指向原会话及反馈条目，不改写原记录。DurableJob 和 UsageRecord 对所属用户及会话有明确关联，避免只凭全局任务 ID 暴露数据。

## 9. HTTP 端点文字契约

以下路径、字段和状态码为建议，具体实现前可调整。除公开注册/登录、持单次凭证确认密码重设与最小健康检查外均需登录认证；密码重设使用专用凭证，不依赖已登录会话。通用错误返回稳定 code、message、request_id、可选 retry_after；不转发上游密钥或未经脱敏的堆栈。401 表示未登录，404 表示本人可见范围无对象，409 表示状态/版本/幂等冲突，422 表示字段不合法，429 表示准入受限，503 表示依赖不可用。

| 方法与路径 | 输入 | 成功结果与边界 |
| --- | --- | --- |
| POST /v1/auth/register | invite_code、username、password、可选 display_name | 201 创建账号与认证会话；邀请原子消耗；Web 写 Cookie，mobile 返回业务 token |
| POST /v1/auth/login | username、password、platform | 200 建立新认证会话；Web 不在响应体暴露 Cookie token |
| POST /v1/auth/logout | 当前认证会话；Web CSRF 信息 | 204 撤销当前会话并清理 Cookie；重复调用安全 |
| POST /v1/auth/password-reset/confirm | reset_token、new_password；Web 来源/CSRF 防护 | 204 原子更新密码、消耗单次凭证、撤销全部登录会话；要求重新登录；不接收目标账号 ID |
| GET /v1/me | 无 | 200 本人基本信息，不返回 password_hash/token_hash |
| GET / PATCH /v1/me/preferences | PATCH 含 difficulty、speech_pace、subtitle_default、chinese_hints_enabled、translation_mode 中的允许字段及期望 version | 200 偏好与新 version；版本冲突 409；首版 translation_mode 仅 on_demand；显示开关可立即生效，生成策略用于新练习，不修改当前或历史快照 |
| GET /v1/topics | 可选分页/类别 | 200 可用的日常主题，不接受自定义上游提示词 |
| POST /v1/practice-sessions | topic_id 或 free_chat、可选难度覆盖；Idempotency-Key | 201 session_id、快照、准入结果；同 key 返回原练习 |
| POST /v1/practice-sessions/{sid}/connections | client_instance_id、expected_epoch；Idempotency-Key | 201连接准备对象、epoch及公开配置；真实准入仍关闭；旧连接未知时拒绝新建，详见实际契约 |
| POST /v1/practice-sessions/{sid}/discard-preparation | expected_epoch | 已实现；锁后验证完整历史未开始上游，原子取消整项准备；unknown拒绝，不调用供应商 |
| POST /v1/practice-sessions/{sid}/connections/{cid}/offer | client_instance_id、epoch、offer；单次受限JSON | 已实现；200 JSON answer，仅进入configuring；失败/重复保持可信边界，网关实际关闭，详见[信令契约](2026-10-17-guarded-signalling-api.md) |
| POST /v1/practice-sessions/{sid}/connections/{cid}/observations | client_instance_id、epoch、1–16条稳定event_id/sequence及受限媒体事实 | 已实现；200完整确认，冲突整批拒绝；client_observed不能推进状态或证明用量，详见[观测契约](2026-10-18-connection-observations-api.md) |
| GET /v1/practice-sessions/{sid}/connections/{cid}/observations | after_sequence、limit（1–32） | 已实现；本人原连接事实的只读快照分页，不接管或续租 |
| PUT /v1/practice-sessions/{sid}/turns/{tid} | connection_id、epoch、revision、最终文字及播放证据 | 200 新版本或同版本原结果；同版本不同内容 409；拒绝封存后静默改写 |
| POST /v1/practice-sessions/{sid}/end | 各连接最终水位、end_reason；Idempotency-Key | 202 ending/finalize 状态；重复返回同一任务；终态返回已有结果 |
| GET /v1/practice-sessions | cursor、limit | 200 本人可见历史；游标稳定排序，不接受 user_id 筛选他人 |
| GET /v1/practice-sessions/{sid} | 无 | 200 快照、连接摘要、最终话语、反馈状态；不返回临时凭证或 SDP |
| POST /v1/practice-sessions/{sid}/assistance | kind 为 english_starter 或 translation、期望上下文 revision；翻译必填 source_turn_id；Idempotency-Key | 202 辅助请求 ID 与状态；核对本人所有权、准入与输入，创建唯一持久任务；已有同一结果可直接返回，不自动朗读 |
| GET /v1/practice-sessions/{sid}/assistance/{aid} | 无 | 200 本人请求状态和辅助文字；失败可显式重试，不能把超时伪装成成功 |
| GET /v1/practice-sessions/{sid}/feedback | 无 | 200 任务/结果状态；生成失败仍能访问原转写 |
| POST /v1/practice-sessions/{sid}/feedback/retry | 期望输入 revision；Idempotency-Key | 202 唯一可重试任务；已有 running/succeeded 返回原状态，不并行重复生成 |
| POST /v1/feedback-items/{item_id}/rehearsals | 可选难度覆盖；Idempotency-Key | 201 新重练会话、同属用户的原会话/条目关联及目标表达 |
| DELETE /v1/practice-sessions/{sid} | 当前用户确认的删除范围；Idempotency-Key | 202 应用数据删除/清理状态；立即从历史和反馈查询隐藏，供应商清理单独表示 |
| GET /v1/deletions/{deletion_id} | 无 | 200 本人最小清理状态；不回显已删除文本 |
| GET /v1/me/usage | 时间区间 | 200 已结算用量、估算、未结算状态及新会话准入；不显示未经验证的“硬封顶” |

辅助请求的相同幂等键返回同一请求；相同输入版本已有成功结果时复用结果。失败后由用户明确重试，创建有来源关联的新尝试并计量，不因轮询、展开文字或页面重新进入而重复生成。

后台只需受管理员认证保护的邀请生成、撤销、账号禁用和单次密码重设凭证签发能力；可先通过内部管理方式操作，不为首版增加公开管理 UI。首版没有自动发送重设邮件/短信的接口。

## 10. 幂等与可靠提交

幂等键由客户端在用户动作开始时生成，重试保持同一键；后端按用户和操作保存 request_hash 及对应资源。超时后先查询原结果，不因一次 HTTP 重试再开一条供应商连接、再建一条练习或再生成一份反馈。SDP 重试只复用同一 connection attempt 的结果；Offer 改变需显式新尝试，不能拿旧 Answer 应答新 Offer。

Turn 使用稳定 turn_id 与单调 revision：同版本同内容是成功重放，旧版本返回当前水位，同版本不同内容冲突。最终文字和播放观测提交使用客户端 outbox，服务器确认后再移除。事件 sequence 只在对应连接内排序；重复、缺口和乱序分别处理，不拿客户端时钟决定唯一顺序。

业务事务不能覆盖外部模型调用。因此采用至少一次任务执行、结果幂等落库：调用之前记录任务和尝试，之后检查输入版本、租约和删除状态再提交；供应商若无幂等支持，崩溃窗口可能重复付费调用，必须在用量中保留未知尝试并限制重试，不能承诺外部 exactly-once。

## 11. 反馈任务与重启恢复

反馈在已固化的文字快照上独立调用文本模型，输出一个下次建议和最多三项原句/建议句/中文解释；内容少时可以无错误项。引用由后端核对 source_turn_id 与原文，不接受把 AI 的建议句当成用户错误。只根据文字提供语法、表达和沟通建议；不输出无音频证据的音素、口音或发音分数。

结束状态与 DurableJob 在数据库事务内一起写入。后端启动时扫描到期 pending/retry_wait 和租约过期 running 任务；运行期间的小型任务循环用数据库行锁与带到期时间的租约领取工作。网络请求不占住长数据库事务；处理器在受限时间内调用供应商，按需续租，提交时确认仍持有任务。多 worker 进程误启动也不能同时提交同一结果。

FastAPI 的 BackgroundTasks 只能提供执行入口，不能承担持久投递或恢复保证；本设计的依据是数据库状态、租约、唯一结果和启动扫描。进程被强制结束后，任务仍在数据库，租约到期会重新被领取；不依赖 Python finally 必定执行。

临时网络错误和供应商限流按有上限的退避重试；参数错误、内容不足等不盲目重试。超过策略上限进入 failed，界面保留原记录及明确重试入口。重试不能绕过用户额度、改变反馈输入或无限增加账单。管理员可以查询脱敏失败码，不能把整段对话作为异常日志。

用户删除会话会取消关联反馈和辅助任务，并清除辅助结果；已经在上游运行的文本调用不一定能撤回，结果返回后必须检查删除标记并丢弃，防止数据重新出现。反馈输入 revision 改变时旧任务作废，新结果不得覆盖不同版本的有效反馈。辅助任务同样使用持久状态、有限重试和用量去重；过时结果只能绑定原输入版本，不伪装成当前话题的新提示。

## 12. 重练、保留与删除

逐句重练创建独立会话，保存 source_session_id、source_feedback_item_id 和最少目标信息。AI 用目标表达帮助用户重新开口，不自动把原练习全文注入。原会话和反馈保持不变，重练产生自己的用户话语和反馈；完成后可返回来源复盘。

**建议的删除默认：** 删除一条原练习时，同时删除其转写、反馈、辅助文字、未完成任务和派生逐句重练，避免目标表达快照变成隐蔽副本；删除单次重练不影响原练习。操作前向用户说明影响的关联记录数量。此级联范围尚需产品确认。若将来改为保留独立重练，必须明确清除来源引用与原文快照，并重新说明保留语义，不能只把外键设空就宣称原数据完全删除。

默认不持久保存原始用户录音或 AI 音频。采集、回声消除、网络抖动和播放所需的短时内存缓冲在结束时释放；浏览器/移动端调试录制默认关闭。数据库、对象存储、日志和备份均不应额外出现音频副本；需要诊断录音时必须作为单独可选方案评审，不能隐式开启。

最终文字、反馈、偏好本身也属于个人数据。建议用户最终文字和反馈保留至用户删除，不自动按练习时间过期。用户删除后，在一个事务内先使对象不可见、撤销写入资格并取消任务，再清除正文及关联；只保留最少删除状态和允许保留的计量字段。

建议数据库备份保留 7 天；删除清单自请求起保留 14 天，只含目标 ID、时间和必要清理状态，不含原话。最新删除清单及必要副本与被恢复的旧数据库快照分开管理，避免回滚时一并丢失；恢复后先重放删除清单并清理关联数据，再向用户开放服务。只使用仍在保留窗口内的备份，不声称即时从所有备份物理擦除。上述期限是自有系统的可审议默认，不适用于供应商侧留存。

应用数据库的删除不等于供应商数据已删除。供应商会接收当前音频、提示词及必要上下文，可能另有会话、日志或留存策略；北京端点本身不能证明零留存。接入前核查处理地域、保留/训练设置、删除接口与终止接口，记录文档和实际配置。无删除能力或无确认时，界面和清理状态如实标记 unknown / not_supported，不作“已从供应商全部删除”的承诺。

## 13. 用量、并发与强制额度边界

建议首版限制每用户同时一个有效练习连接，并在创建练习、建连、重连和反馈重试前检查准入。先预留会话预算，再用可信用量结算；客户端在线时长、服务器观察时长、供应商确认音频/Token 单位分别记录。估算金额保存单价版本，可信结算到来后替代对应估算，不重复累加。没有结算证据时显示待结算，不把未知当作零。删除练习不返还已发生的调用额度；最小账本建议自调用发生起保留 90 天，仅保留必要计量、来源及去重字段，不存用户原话。此期限可评审，不是供应商账单保留政策。

**直接媒体连接的关键限制：** 代理 SDP 后，业务后端可能不再位于媒体或模型控制路径上。后端宕机、撤销本项目登录凭证或标记额度耗尽，都不必然关闭已经建立的供应商连接。客户端计时、心跳、关闭回调、令牌的建连有效期也不自动等于已连会话最大寿命。修改客户端还可能绕过本地停播和计时。

只有以下至少一条经过官方资料与实测确认，才可对相应边界承诺服务端强制结束：供应商提供可由本后端调用且有效的会话终止接口；服务端签发并由上游执行不可延长的会话 TTL/最大用量；或服务端持有必须经过的上游连接并能切断它。即使可终止，也需计入延迟上报、终止传播及供应商计费粒度，不能无条件承诺金额绝不超出。

若首轮直连候选缺少上述证据，只能提供新会话准入、并发限制、客户端提醒及估算账单；是否接受这一试用风险必须作为显式选型决定。若硬上限是必需条件，则改选具备受控会话能力的路线，不能用数据库多加一个 quota 字段来代替闭环。

同样，前端转发的 usage 事件可能被修改或漏报。没有供应商服务端回调/账单查询时，不把它当成对抗滥用的可信扣费依据。供应商总账单与内部用量需可对账；失败建连和重连期间的未知消耗单独保留。

## 14. 候选供应商与有条件的替代路线

| 路线 | 当前判断 | 进入下一阶段的条件 |
| --- | --- | --- |
| 千问北京 WebRTC + flutter_webrtc | 第一轮候选，尚未集成 | 可开通模型/业务空间；三端连续双向音频；自然插话和旧音频清理；用户/AI 转写与已播放上下文；可靠关闭及用量边界均有证据 |
| 国内托管 RTC / 对话引擎 | 条件性替代，未选定厂商 | 直接 WebRTC 的设备、弱网、打断或强制控制不满足要求时评估；核查国内实际区域、模型、服务端终止、计费和许可 |
| Flutter + LiveKit/Agents + 国内模型 | 条件性替代，增加媒体运行组件 | 需要服务端持有媒体/上游、可观测播放或更强控制，且接受额外运维和部署成本时再评估 |

官方 Realtime 概览列出多个协议和模型系列；最终型号、价格、权限和限流需要在实际账号中核对，本文不锁定一个未经验证的型号。[Realtime API 概览](https://help.aliyun.com/zh/model-studio/realtime-api-overview)

供应商评估记录必须包含模型/区域/版本、设备与网络、轮次策略、打断/截断能力、上游终止与 TTL、可信用量来源、数据留存以及实际账单。自然度、接话和打断质量的判定统一使用验证文档；先得到实际结果，再决定是否满足用户目标及可接受费用，不能预先写预算可控。

替代路线在一次练习之间切换，不在通话中无提示跨供应商迁移。保留相同业务会话和适配事件，但重新建立连接并重建有限文本上下文；音色、延迟和上下文可能变化。LiveKit 路线若引入独立媒体运行时，应重新评审部署图；“一个业务后端”仍成立，但不能把新增媒体组件隐去。

## 15. 开源证据能支持什么

[Nia 的固定源码快照](https://github.com/bielcarpi/nia/tree/9a97e911075c7740e6c5c2b8bf46e1002fc2070d)提供 Flutter、WebRTC、独立偏好、会后反馈和私人历史的可读实现；[实时客户端](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/mobile/lib/realtime/realtime_client.dart)、[服务端凭证与提示词](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/api/internal/provider/openai/client.go)和 [BSD-3-Clause 许可证](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/LICENSE)已检查。它支持本设计借鉴业务闭环与边界划分，不证明本项目选定供应商的全双工、费用或可靠队列已经实现。

Nia 默认 demo 是脚本会话；其 OpenAI/Firebase/Go 接法也不等于本项目要采用同一后端。uiniq 可参考国内服务与评测思路，但录音回合提交不能替代本项目自然全双工验收；Agora Flutter quickstart 可参考 RTC/VAD，实际默认区域及模型需另查。详细证据统一保留在[调研记录](../research/2026-10-15-product-and-stack-review.md)，不把示例仓库当作生产就绪证明。

## 16. 待协调的决定与开发前门槛

1. 主产品文档明确 Flutter 与产品范围已确认；Riverpod、路由、后端、数据库、认证和数据策略仍是推荐。此技术文件不替代用户确认。
2. 确认前台练习及后台/锁屏暂停策略；评审删除原练习级联派生重练、用户文字保留至删除，以及第 1 节的认证、补交、备份、删除清单与计量保留默认值。
3. 明确试用阶段是否接受直连媒体缺少服务端硬上限；如果不接受，服务端终止/可信 TTL 必须成为候选准入条件。
4. 验证选定模型在 WebRTC 下的取消、输出清空、转写、播放边界和上下文修正；任何未知能力不得写成已支持。界面按钮可以控制接话，但不能替代自然插话要求。
5. 验证三端、实际大陆网络、外放/耳机、权限、自动播放、进后台与恢复；质量阈值由独立验证文档定义。
6. 按建设路线尽早验证真实语音，再确定供应商配置与额度承诺；每阶段开始时编写对应实施任务。当前工作边界以最新用户指令和根目录 HANDOFF.md 为准。
