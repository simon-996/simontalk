# SimonTalk 技术设计

2026-10-26实现更新：[一级重练改善评价](2026-10-26-rehearsal-evaluation.md)以review_result_v1可选扩展复用原任务/结果，无新增表或队列；新子评价绑定当前子封存输入与复验目标，分别判断原意/目标问题。普通wire与旧存量读取保留；启用新生成前配套更新严格客户端。实际固定样本与本人页面证据见[验证](../development/2026-10-26-rehearsal-evaluation-verification.md)，不作为真实媒体准入。

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
| 默认仅保存文字及反馈 | 数据策略建议，沿用现有边界 | 供应商侧留存仍待核查，不默认保存原始音频 |
| 一级重练及删除范围 | 用户已确认一级关联；本次明确相应删除规则 | 普通练习删除覆盖全部直接重练；单次重练删除不影响来源及同级 |
| 千问北京地域 WebRTC + flutter_webrtc | 首轮技术候选 | 不表示三端已经可用、体验达标或预算可控 |
| 前台练习，进入后台或锁屏暂停拾音 | 产品与技术建议，未确认 | 返回后新建连接并显式恢复上下文 |

本文提出工程边界和文字形式的接口契约，不生成 API schema 或实现代码。产品范围以[首版设计](../superpowers/specs/2026-10-15-simontalk-mvp-design.md)为索引，选型证据见[调研记录](../research/2026-10-15-product-and-stack-review.md)。质量阈值、测试网络和真机矩阵统一由[验证计划](../validation/2026-10-15-validation-plan.md)维护，本文不重复承诺延迟或成功率。

2026-10-16 实施更新：账号与偏好的工程基线见[基础决策](2026-10-15-foundation-decisions.md)，当前可调用接口以[账号契约](2026-10-15-account-api.md)为准。本文其他模块仍是后续设计，不表示已实现。

2026-10-20补齐的[收尾、恢复准入与反馈依据契约](2026-10-20-practice-completion-and-review-contract.md)是相应实现与验收的统一入口，包含总纲D13、D17–D20。2026-10-21已有客户端有界end、独立前缀/上下文门及[播放证据账本](2026-10-21-playback-evidence.md)，本批进一步接入[正常结束、固定补交与输入固化](2026-10-21-practice-finalization.md)。供应商收尾/对齐/截断、可信终止执行器、完整反馈资格及跨进程上下文恢复仍缺；本批最终实测与全量证据见[验证报告](../development/2026-10-21-practice-finalization-verification.md)，不提前据此标记真实语音完成。

以下是本项目自有系统参数。认证期限已随账号基础工程采用，其余保留策略仍为建议；收尾参数属于本次设计的工程默认，不是用户逐项批准或供应商承诺，调整须保留验证依据。

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
| Web 未确认文字与播放证据 | 仅当前账号的练习作用域内存 | 不持久缓存；刷新或关闭可能丢失未确认内容，未封存播放读取不能自动恢复上下文 |
| 正常结束/单个被打断回复的文字收尾 | 默认3秒，配置1–5秒 | 从首次动作起按单调时钟计，原租约更早则提前结束，不因事件或重试延长 |
| 最终文字补交窗口 | 首次结束请求受理后30秒 | 只等待已产生的文字提交；与本地收尾、供应商终止和费用结算分开，不延长媒体 |

## 2. 单仓库与模块边界

2026-10-22实施编排：按[基础版本开发路线](../superpowers/plans/2026-10-22-basic-version-development.md)优先复用现有账号、准备/恢复、媒体协调、两账本、固化与复盘模块，接普通练习主流程及本人历史/删除。真实准入、信令和协议的开启依赖相应供应商验证与输入，页面成功状态不得绕过该门槛。新增历史/删除接口须在其单元明确身份、分页、完整范围确认和未知连接保留规则；本轮不另建媒体底座，也不因已有一级重练后端继续优先扩展重练客户端。各项既有契约的安全/数据边界保留。

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
| end | 异步登记正常结束意图，同时立即停麦停声，按原输入边界有界接收收尾事实；随后封存、释放并固定提交清单，重复动作不延长截止 |
| stop / dispose | 后台、身份变化、故障及销毁立即封闭回调并释放；不等待收尾，不恢复旧媒体；身份变化清空原话 |

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

AI的generated_text与played_text分开：前者是某个生成文字版本，可为interim或final，后者是该版本有播放证据的前缀。delivery_status为played、partial、not_played或unknown；另存played_until_ms与依据/精度。所谓“已播放”指已交付设备输出，不能证明用户确实听见或理解。

response.done 或音频生成完成不等于扬声器缓冲已播放完成。没有可靠字词/音频对齐时，不按字符比例从毫秒数推算“精确听到的句子”。打断后的未知后缀在历史中标明，反馈和重建上下文不将其作为已交流的事实；客户端可展示带“未播完”标记的生成文本。

2026-10-18已实现[客户端内存对话投影](2026-10-18-conversation-projection.md)，通过媒体控制器受保护的归一化协议回调消费明确文字/播放事实。按账号/原连接/代次绑定，临时/最终文字、生成/已对齐播放前缀分离，严格修订与容量限制；正常stop封存，账号变化/销毁清空。来源固定client_reported，原始传输播放事件不制造文本，默认协议仍Unavailable。2026-10-20新增[最终文字追加/读取与确认队列](2026-10-20-final-transcript-storage.md)，按原连接保留最终修订而非覆盖；其AI生成文本读取保持delivery_status=unknown。2026-10-21另增[独立播放证据账本](2026-10-21-playback-evidence.md)，自含保存alignment、首次freeze和永久revoke，原账号/连接/epoch确认队列及分页history保留来源版本，与最终文字双向核验。前批真实Dart→HTTP→测试PostgreSQL已验证存取及隔离；本批新增服务端固化及候选话轮引用，播放GET的sealed随固化单向变化、recoverable仍false。真实供应商事件、完整反馈资格验证及后文完整Turn实体仍待实现。

同日新增[客户端文字读取与只读查看](2026-10-20-final-transcript-read.md)：绑定原账号/连接分页读取，按最大修订重建当前文字，空修订覆盖旧原话；跨页核验原子发布，间隔/部分读取不被当作完整会话。现有未结束练习入口可明确查看/翻页/刷新，AI生成内容仍显示播放未知，不提交新文字或控制媒体，也不是全练习历史列表。

### 5.3 打断必须同时解决三件事

1. **本地停播：** 确认用户开始说话或点击“我来说”后，停止当前输出并清空可控制的队列，提升播放代次；旧response后续音频不得再播放，后续文字不得驱动新播报。仍在有界窗口内接收原回复的终态转写与对应输出证据，用于封存已播放前缀。持续监听上行，并处理外放回声，不能靠轮流静音伪装全双工。
2. **取消生成：** 对当前 response_id 发送供应商支持的取消操作；自动取消和手动取消重复发生时仍幂等。等待确认或超时，记录实际结果，不把本地静音当作取消成功。
3. **修正上下文：** 将旧 AI 回复截断至有证据的播放边界；若模型仅支持删除/重建，则删除整条并只补回可确认前缀。若无法可靠调整旧连接，结束它并以确认文本创建新连接；只有该替代行为通过验证，才可接受为候选实现。

已经单独封存且有版本绑定输出证据的前缀可作为中断上下文，不以整条AI生成文字final为必要条件；它不能伪装成完整最终转写。2026-10-21内存投影及独立持久账本已有此前缀与撤销；新revision保持播放unknown，旧可靠前缀仍按原版本保存。新回复须经原scope/通道和精确不可变token的上下文控制确认，本地门才放行；旧AI终态在原窗口内继续保存而不改历史token，推翻已用依据时先入队撤销、再安全停止。本批固化保留原版本输出引用，仍不自动恢复上下文；供应商截断与真实播放路由仍待验证，见[收尾契约第3节](2026-10-20-practice-completion-and-review-contract.md#3-自然插话后的文字与上下文)。

RTP 音频不像逐帧应用消息那样必然带 response_id；仅 mute 后立刻 unmute 可能播出旧抖动缓冲。适配器需验证供应商清空输出、取消确认和远端音轨的实际行为；若无法区分残留旧音频与新回复，不得宣称打断完成。

千问不同模型的事件、轮次和取消能力需分别验证；不能从 WebSocket 示例推定所有 WebRTC 模型都具有精确截断或播放进度。[模型协议边界](https://help.aliyun.com/zh/model-studio/realtime-webrtc-access)及 [Qwen-Audio 交互说明](https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides)作为候选评估依据。

### 5.4 结束与转写固化

2026-10-20用户确认正常结束立即停麦停声，短暂等待最后一句最终识别。2026-10-21客户端`end`已有固定截止收尾，`stop/dispose`保留立即释放；具体允许事件、输入映射和截止以[收尾契约第2节](2026-10-20-practice-completion-and-review-contract.md#2-正常结束与立即释放)为准。TurnStartedUpdate登记尚无字幕的已发输入；默认3秒、可配1–5秒，取原租约更早截止，重复事件/动作不顺延。正常收尾停止续租并忽略在途续租/播放的旧结果，账号变化、后台、租约失效与销毁仍立即释放。没有可核验的供应商完成依据时到期tail_unconfirmed；本批接入服务端正常end，正式结束页面和供应商行为仍待实现与实测。

当前正常结束采用两阶段：原连接end先登记意图，后端事务性保存ending、全部成员范围及首次受理后固定30秒补交截止；客户端媒体drain结束后固定两账本全部事件ID/sequence清单、累计预算和已知缺口，再提交manifest。声明水位不等于实收；只有实际集合/统计核对后才可提前固化。未发end的普通异常stop继续中断，不自动登记产品正常结束。原账号作用域保留两队列及completion操作，同账号离页不取消，身份变化/销毁abort。

两个追加API已共同约束固定截止、manifest身份清单和封存：新事件到期或sealed返回practice_input_sealed，精确旧事件仍可确认；混合批次整体失败。maintenance依据持久ending限量固化，GET纯读；每成员snapshot及全局input_revision=1/hash、coverage与gap_codes不可变，父练习completed不解除unknown占用。客户端取得匹配全局hash的原scope receipt后，实际未收pending记永久未保存并停止重试，不能无限保活。当前final_text_candidate_v1只派生候选话轮资格及原版本输出引用，没有创建反馈任务；完整质量规则、引用检查和反馈生成仍待后续。实际wire及边界见[固化契约](2026-10-21-practice-finalization.md)。

## 6. 断线、离开页面和恢复

区分短暂 ICE 抖动、DataChannel 关闭、模型错误、业务 API 不可用和整个 App 重启。只有供应商文档与验证明确支持同一会话恢复时，才使用其原生 resume；不假定 ICE restart、重新交换 SDP、跨模型或跨供应商连接能延续原来上下文。

建议首版恢复方式：停止旧采集与播放 → 关闭旧连接并记录终止结果 → 向业务后端获取最新有效连接代次和确认话语 → 新建媒体连接 → 明确提示“已重新连接，继续刚才的话题” → 注入难度/话题快照及有限的已确认文本。重建内容只含用户最终话语和可确认的 AI 已播放部分；没有原始音频可重传，也不自动重播最后一句。

后端仍使用同一逻辑练习 ID，连接代次递增，拒绝旧连接的状态推进和晚到话语污染；旧转写补交走受限的结算窗口。无法确认旧上游已关闭时，标 orphaned/unknown 并执行清理；若可能产生并行付费且无上游控制，不自动发起多次连接。

unknown可以在允许的输入窗口保存已有内容，但不能恢复或新建连接。只允许未启动上游证据、绑定原attempt的可信终止结果，或已核验的不可延期上游失效边界解除占用；客户端关闭和租约到期均不够。本批end、信令失败、租约unknown及维护补齐会去重登记blocked/capability_unavailable核验意图，attempts=0，无执行器或外部调用。有界上游核验重试仍须供应商能力实测后实现，当前不把blocked写成终止成功。删除正文不能删除占用证据来绕过准入。详见[收敛规则](2026-10-20-practice-completion-and-review-contract.md#4-unknown连接的收敛与准入)。

App 进入后台、锁屏或用户离开通话页时，建议暂停并停止拾音；再次进入显式新建连接。Web pagehide、App 生命周期回调及网络通知均是尽力而为，不能依赖它们必定执行。服务端根据持久连接租约和失联扫描收拢业务记录；失联收拢不等于远端媒体已被服务端强制终止。

客户端为提交可靠性暂存当前账号的最终文字和自含播放证据及必要ID；播放journal在采集期间保留有界来源校验状态，finish且全部确认后释放正文，不缓存音频、凭证或全部历史。移动端建议使用保护的文字 outbox，例如由系统安全存储管理密钥的加密存储；首次入队起最长保留 24 小时，服务器确认、到期或退出账号时删除，重试不顺延期限。重开 App 时先核对账号和会话状态，跨账号不得补交；存储实现仍需平台验证。

Web首版只把未确认文字和播放证据放在当前账号的练习作用域内存；离页可继续收尾/确认，不写localStorage、IndexedDB或其他持久缓存。刷新、关闭页面或浏览器回收页面后，这部分可能丢失；只读查看服务端已确认记录，并如实标记未封存及不完整边界。播放分页不能自动恢复上下文，不能承诺浏览器具有受保护的持久文字存储或保证恢复未提交内容。这些都是可审议的数据策略默认。

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
| PlaybackEvidence（已实现） | 原connection/client_instance/epoch、event_id/sequence、kind、turn/response、文字与播放revision、自含生成/播放文字、停止上限/原因、source/received_at | 独立alignment/freeze/revoke追加；与final_transcripts双向核验，来源client_reported；受补交/固化门保护，读取仍不可恢复 |
| PracticeCompletion / CompletionConnection（已实现） | 首次end key/digest、origin、accepted_at/deadline、固定成员、manifest/digest、snapshot/hash、input_revision、coverage/gap_codes | 唯一结束记录和每连接身份；持久ending由maintenance固化，不依赖内存任务；版本1不再追加新内容 |
| TerminationCheck（已实现意图） | 原connection/client_instance/epoch、attempt_digest、status/reason/attempts、created_at | 当前固定blocked/capability_unavailable/0，按原attempt去重，无可信终止执行能力 |
| InterruptedPrefix（内存及独立账本已有） | 原连接/epoch、turn/response、文字与播放revision、前缀、输出位置、停止上限、证据来源、封存原因 | 保留原来源版本的输出事实；同一内存上下文可独立于整轮生成final使用，持久读取仍无恢复资格，不能经transcripts冒充完整final |
| ReviewEligibility（候选引用已有，完整策略待实现） | turn_id、revision、eligible/uncertain/excluded、reason_codes、policy_version、证据来源 | final_text_candidate_v1随snapshot保存；完整质量/上下文规则及反馈输入验证仍缺，候选资格不等于识别准确性证明 |
| Feedback | id、session_id、user_id、transcript_revision/hash、prompt_version、model、status、next_step、created_at | 同一会话输入版本和提示词版本只有一份有效结果 |
| FeedbackItem | id、feedback_id、user_id、source_turn_id、original_quote、suggestion、explanation_zh、kind、uncertainty | 最多三项，引用须能在当前用户最终话语中定位 |
| RehearsalResult（待实现） | session_id、来源版本、目标快照、本次输入revision/hash、meaning_status、target_status、本次话轮引用与解释 | 来源仅普通练习反馈；允许不同措辞，未展示目标与证据不足分开，不给总分或长期掌握结论 |
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
| GET /v1/topics | 可选分页/类别 | 可更新目录的候选接口。首批四个固定主题随客户端发布，后端核验 ID |
| POST /v1/practice-sessions | `mode=free_chat` 或 `mode=daily_topic`。后者必填固定 `topic_id`，均可覆盖难度，须带 Idempotency-Key | 已实现。201 返回练习和配置快照，同原输入及 key 可返回原练习。话题只接受目录 ID，由后端生成会话配置 |
| POST /v1/practice-sessions/{sid}/connections | client_instance_id、expected_epoch；Idempotency-Key | 201连接准备对象、epoch及公开配置；真实准入仍关闭；旧连接未知时拒绝新建，详见实际契约 |
| POST /v1/practice-sessions/{sid}/discard-preparation | expected_epoch | 已实现；锁后验证完整历史未开始上游，原子取消整项准备；unknown拒绝，不调用供应商 |
| POST /v1/practice-sessions/{sid}/connections/{cid}/offer | client_instance_id、epoch、offer；单次受限JSON | 已实现；200 JSON answer，仅进入configuring；失败/重复保持可信边界，网关实际关闭，详见[信令契约](2026-10-17-guarded-signalling-api.md) |
| POST /v1/practice-sessions/{sid}/connections/{cid}/observations | client_instance_id、epoch、1–16条稳定event_id/sequence及受限媒体事实 | 已实现；200完整确认，冲突整批拒绝；client_observed不能推进状态或证明用量，详见[观测契约](2026-10-18-connection-observations-api.md) |
| GET /v1/practice-sessions/{sid}/connections/{cid}/observations | after_sequence、limit（1–32） | 已实现；本人原连接事实的只读快照分页，不接管或续租 |
| POST/GET /v1/practice-sessions/{sid}/connections/{cid}/transcripts | client_instance_id、epoch、最终文字修订事件；GET为sequence分页 | 已实现受限追加/读取与精确event确认，source=client_reported，AI播放状态unknown；追加受固定补交与seal门保护，固化状态另读completion |
| POST/GET /v1/practice-sessions/{sid}/connections/{cid}/playback-evidence | client_instance_id、epoch、1–4条alignment/freeze/revoke；GET limit1–16按sequence分页 | 已实现独立版本证据/首次冻结/永久撤销及精确ACK；追加受补交与seal门保护；sealed随服务端固化变化，recoverable=false |
| PUT /v1/practice-sessions/{sid}/turns/{tid} | connection_id、epoch、revision、最终文字及播放证据 | 后续完整Turn建议契约，尚未实现；需协调追加事件与封存语义 |
| POST /v1/practice-sessions/{sid}/connections/{cid}/end | client_instance_id、epoch；Idempotency-Key | 已实现；200统一摘要，首次固定30秒补交截止及全部成员，重放不延期，不解除unknown占用 |
| POST /v1/practice-sessions/{sid}/connections/{cid}/completion-manifest | 原scope、两ledger全部ID/sequence及预算、tail与缺口 | 已实现；每成员固定一份，精确重放可确认；新清单到期/sealed为409；返回origin摘要 |
| GET /v1/practice-sessions/{sid}/completion | 无 | 已实现；server_recorded全局ending/sealed及revision/hash/coverage/gap_codes，纯读 |
| GET /v1/practice-sessions/{sid}/saved-transcript | input_revision=1、input_hash；可选offset、limit1–16、review_item_id | 已实现本人sealed纯读投影；完整来源/引用门后按成员及话轮分页，普通读取不依赖review任务；详见[已保存文字契约](2026-10-22-saved-transcript.md) |
| GET /v1/practice-sessions/{sid}/review-items/{item_id}/rehearsal-target | 无 | 已实现有效ordinary来源目标，完整源/quote门及64KiB目标限额 |
| POST /v1/practice-sessions/{sid}/review-items/{item_id}/rehearsals | target_hash、可选difficulty_override；Idempotency-Key | 已实现独立一级准备及同key确认；默认准入关闭，无半记录 |
| GET /v1/practice-sessions/{sid}/rehearsal-target | 无 | 已实现子固定目标和当前来源双重核验 |
| GET /v1/practice-sessions/{sid}/rehearsals | limit1–20、可选before_id | 已实现本人普通父同级元数据seek，见[一级重练契约](2026-10-22-rehearsal-preparation.md) |
| GET /v1/practice-sessions/{sid}/connections/{cid}/completion | 无 | 已实现；原scope临时覆盖或固化snapshot及候选话轮/前缀引用，recoverable=false |
| GET /v1/practice-sessions/{sid}/connections/{cid}/completion-receipt | 无 | 已实现；封存实收IDs、成员hash及全局hash，供pending明确收敛；未固化409，不证明上游终止 |
| GET /v1/practice-history | cursor、limit（1–20，默认10） | 已实现；本人摘要，created_at/id倒序tuple seek，账号绑定游标，不加载正文 |
| GET /v1/practice-history/{sid} | 本人ID | 已实现。返回当时的话题（如有）、难度、业务及保存状态，连接占用独立。跨账号与不存在统一404 |
| GET /v1/practice-sessions/{sid} | 无 | 200 快照、连接摘要、最终话语、反馈状态；不返回临时凭证或 SDP |
| GET /v1/practice-sessions/{sid}/assistance/context | 原 connection_id、epoch、kind。翻译须指定 source_turn_id 和 source_turn_revision | 已实现。只读返回可用状态、固定输入摘要和同输入请求 ID。不返回原话 |
| POST /v1/practice-sessions/{sid}/assistance | 原连接、kind、input_revision，翻译也带精确话轮 ID 和版本。使用 Idempotency-Key | 已实现。202 返回辅助请求状态，按本人、当前连接和同输入复用 |
| GET /v1/practice-sessions/{sid}/assistance/{aid} | 无 | 已实现。本人和原版本核验后返回请求状态和独立文字 |
| POST /v1/practice-sessions/{sid}/assistance/{aid}/retry | 原请求字段、attempt_count、Idempotency-Key | 已实现。仅明确知道可重试且未耗尽时允许，不重发结果未知的调用 |
| POST /v1/practice-sessions/{sid}/review-input | input_revision、原input_hash | 已实现；绑定原seal的资格/引用投影；GET同路径纯读，见[复盘输入](2026-10-21-review-inputs.md) |
| POST /v1/practice-sessions/{sid}/review | 原input_revision、practice_input_hash、review_input_hash、policy_version；Idempotency-Key | 202持久任务；同输入复用，默认blocked/0次，见[反馈任务](2026-10-21-review-jobs.md)；没有真实模型适配 |
| GET /v1/practice-sessions/{sid}/review | 无 | 200本人当前任务及通过来源/引用/hash校验的结果；纯读，不自动创建或重试 |
| POST /v1/practice-sessions/{sid}/review/retry | job_id、expected_attempts；Idempotency-Key | 202原任务状态；仅允许状态且未耗尽、无不可重试未知调用时排队，新key不能绕过上限 |
| POST /v1/feedback-items/{item_id}/rehearsals | 可选难度覆盖；Idempotency-Key | 待实现；201新重练；来源必须为本人未删除普通练习的有效反馈；重练来源或失效反馈409，删除/他人404 |
| GET /v1/practice-history/{sid}/deletion-scope | 无 | 已实现；本人完整一级范围数量/hash和连接待核对，纯读 |
| DELETE /v1/practice-history/{sid} | scope_version；Idempotency-Key | 已实现；锁内复核完整成员，变更409；同步清除内容后200凭据，未知占用单独保留 |
| GET /v1/practice-history/{sid}/deletion | key | 已实现；本人原请求凭据，不回显正文；404缺凭据不能认作成功 |
| GET /v1/me/usage | 时间区间 | 200 已结算用量、估算、未结算状态及新会话准入；不显示未经验证的“硬封顶” |

辅助请求的相同幂等键返回同一请求；相同输入版本已有成功结果时复用结果。失败后由用户明确重试，创建有来源关联的新尝试并计量，不因轮询、展开文字或页面重新进入而重复生成。

后台只需受管理员认证保护的邀请生成、撤销、账号禁用和单次密码重设凭证签发能力；可先通过内部管理方式操作，不为首版增加公开管理 UI。首版没有自动发送重设邮件/短信的接口。

## 10. 幂等与可靠提交

幂等键由客户端在用户动作开始时生成，重试保持同一键；后端按用户和操作保存 request_hash 及对应资源。超时后先查询原结果，不因一次 HTTP 重试再开一条供应商连接、再建一条练习或再生成一份反馈。SDP 重试只复用同一 connection attempt 的结果；Offer 改变需显式新尝试，不能拿旧 Answer 应答新 Offer。

完整Turn建议使用稳定turn_id与单调revision；其旧版本返回当前水位的语义尚未实现。当前transcripts及playback-evidence分别使用精确event_id重放确认，新sequence须前进，文字/播放版本冲突明确409，避免“收到”与“当前版本”混淆。两种队列独立核对原身份、请求IDs和累计统计，未确认内容由原账号作用域持有；播放事件自含来源，不依赖文字先ACK。移动保护存储和服务端封存待实现；事件sequence只在各自账本的原连接内排序，允许缺口，不拿客户端时钟决定对话顺序。

业务事务不能覆盖外部模型调用。当前专用review任务在调用前持久记录任务和尝试，事务外生成，回写时复核输入版本、租约和来源再原子提交唯一结果。ReviewAction将本人动作key绑定操作/路径/body；同输入换key仍复用原任务。崩溃、超时或租约失效可能留下未知调用：保留无正文attempt及未知用量；没有经验证的供应商幂等能力就不自动或手动再次调用，具备该能力才复用固定logical key有限重试，不承诺上游exactly-once。

## 11. 反馈任务与重启恢复

反馈在已固化的文字快照上独立调用文本模型，输出一个下次建议和最多三项原句/建议句/中文解释；内容少时可以无错误项。引用由后端核对 source_turn_id 与原文，不接受把 AI 的建议句当成用户错误。只根据文字提供语法、表达和沟通建议；不输出无音频证据的音素、口音或发音分数。

2026-10-20用户确认首版不提供用户转写纠错入口。[反馈依据契约](2026-10-20-practice-completion-and-review-contract.md#5-反馈依据与不确定性)将话轮资格分为eligible/uncertain/excluded，并保存原因、版本与实际证据；没有confidence不自动排除正常句子，也不编造分数。对疑点仅跳过依赖它的结论，不把学习者语法错误本身当ASR异常。没有可评价内容是正常结果，技术失败才进入有界重试；页面说明建议基于识别文字，最终识别与引用存在不证明准确性。

当前输入固化使用PracticeCompletion持久ending及独立maintenance扫描；反馈另用专用ReviewJob、ReviewAttempt、ReviewAction、ReviewResult，不引入通用DurableJob。任务固定原ReviewInput及generation_policy_version，默认Unavailable正常输入blocked/0次，无可评价直接no_evaluable_content。ReviewJobRunner在lifespan按有界周期扫描queued、到期retry_wait及过期running，User→Practice→Job短锁领取并提交15秒lease/fence，再在事务外最多等待8秒。回写重新核对原账号、来源、hash/policy、当前token、lease和精确原话，完整通过才保存0–3项及稳定item ID/hash。具体状态、接口和边界见[反馈任务契约](2026-10-21-review-jobs.md)；真实模型适配、费用准入和人工语言质量仍待后续。

FastAPI的BackgroundTasks不能承担持久投递或恢复保证；本实现依据数据库状态、租约、唯一结果和重启后周期扫描。进程被强制结束后，任务仍在数据库；过期running先标记outcome_unknown，再按已捕获的供应商幂等能力决定是否有限重试，不无条件重新调用，也不依赖Python finally必定执行。

2026-10-25新增[千问文本反馈候选边界](2026-10-25-qwen-review-gateway.md)，只复用既有ReviewGateway/worker，默认工厂仍关闭。固定北京workspace/qwen-flash、去除业务UUID的有界JSON、7秒/256KiB单次HTTP、精确本地引用映射及nullable用量；坏Chat外层保留unknown且非幂等不再调用，完整最终消息的非法建议才为invalid_output。实际权限、预算、响应兼容性和语言质量仍待实测，不改变schema/准入/客户端。

gateway明确可安全重试的临时错误按2/8秒退避，自动与明确重试合计最多3次调度；超时或未知异常仍走上述unknown门。非法结构/引用和永久错误进入failed，不保存未校验响应；有效空建议为no_suggestions，不代表证明没有问题。新动作key不能改变输入或重置次数。尝试仅保存脱敏配置/结果分类和nullable真实报告用量，无prompt、原话、异常正文；这些元数据不构成完整额度或计费系统。完整复盘/一级重练流程与成本准入尚未接通。

用户删除会话会取消关联反馈和辅助任务，并清除辅助结果；已经在上游运行的文本调用不一定能撤回，结果返回后必须检查删除标记并丢弃，防止数据重新出现。反馈输入 revision 改变时旧任务作废，新结果不得覆盖不同版本的有效反馈。辅助任务同样使用持久状态、有限重试和用量去重；过时结果只能绑定原输入版本，不伪装成当前话题的新提示。

配套[原账号Dart客户端](2026-10-21-review-client.md)提供sealed输入目标、严格任务/结果模型、明确创建和重试、纯读刷新及固定动作重放。每操作含CSRF共用8秒并独立关闭HTTP；网络不确定保留原key/body，确定409冲突先读当前状态再明确建动作，未知调用禁止客户端另发生成。账号/来源变化和dispose清正文，provider构造/监听不请求。

[复盘入口与阅读页](2026-10-21-review-page.md)将恢复面板的本人sealed摘要接入`/practice/:sessionId/review`。来源GET与原任务读取分为独立8秒阶段；网址刷新重新确认来源，初进纯读，所有生成/重试/原动作确认均须明确点击。源读撤旧，同target保留pending；账号/来源失效清理。页面只展示实有状态和0–3项，不推断时长/分数/可信终止；完整对话、话轮定位、一级重练、完整历史及真实模型仍待接通。[本批验收](../development/2026-10-21-review-page-verification.md)。

## 12. 重练、保留与删除

逐句重练创建独立会话，来源仅为普通练习的有效反馈项，保存source_session_id、source_feedback_item_id、来源版本和最少目标快照。重练反馈不能继续派生；“再练一次”固定引用原普通练习与原反馈，并创建独立记录和用量。AI用目标表达帮助开口，不自动注入原练习全文。所有权、来源类型/版本与未删除状态在同一锁序下核验，重复请求不重复创建。

2026-10-20用户确认重练反馈判断原意是否表达、目标问题是否改善，允许不同说法。原意状态为conveyed/changed/insufficient_evidence；目标状态为demonstrated/still_present/not_demonstrated/insufficient_evidence，均引用本次话轮版本。若换日常情境，开始前展示并冻结当次表达意图。目标未展示不等于能力失败，一次达到不等于长期掌握，不以字面相似度代替判断。契约见[一级重练规则](2026-10-20-practice-completion-and-review-contract.md#6-一级重练评价与删除)，尚未实现。

**一级关联下的删除规则：** 删除普通练习包括其转写、反馈、辅助文字、未完成内容任务及全部直接重练；删除单次重练仅影响该次及自身反馈。先查询完整范围，确认后锁内复核，数量变化需重新确认。创建重练与删除共享User→来源Practice锁序，删除后不能再派生。正文立即隐藏并清除，仍占用的连接及终止核验保留无正文标识直到可信收尾；不能把父记录物理级联删除当作媒体已经终止。若异常数据出现多层关系，拒绝不完整删除并核对真实范围，不静默漏删。

默认不持久保存原始用户录音或 AI 音频。采集、回声消除、网络抖动和播放所需的短时内存缓冲在结束时释放；浏览器/移动端调试录制默认关闭。数据库、对象存储、日志和备份均不应额外出现音频副本；需要诊断录音时必须作为单独可选方案评审，不能隐式开启。

最终文字、反馈、偏好本身也属于个人数据。建议用户最终文字和反馈保留至用户删除，不自动按练习时间过期。用户删除后，在一个事务内先使对象不可见、撤销写入资格并取消任务，再清除正文及关联；只保留最少删除状态和允许保留的计量字段。

建议数据库备份保留 7 天；删除清单自请求起保留 14 天，只含目标 ID、时间和必要清理状态，不含原话。最新删除清单及必要副本与被恢复的旧数据库快照分开管理，避免回滚时一并丢失；恢复后先重放删除清单并清理关联数据，再向用户开放服务。只使用仍在保留窗口内的备份，不声称即时从所有备份物理擦除。上述期限是自有系统的可审议默认，不适用于供应商侧留存。

应用数据库的删除不等于供应商数据已删除。供应商会接收当前音频、提示词及必要上下文，可能另有会话、日志或留存策略；北京端点本身不能证明零留存。接入前核查处理地域、保留/训练设置、删除接口与终止接口，记录文档和实际配置。无删除能力或无确认时，界面和清理状态如实标记 unknown / not_supported，不作“已从供应商全部删除”的承诺。

## 13. 用量、并发与强制额度边界

建议首版限制每用户同时一个有效练习连接，并在创建练习、建连、重连和反馈重试前检查准入。先预留会话预算，再用可信用量结算；客户端在线时长、服务器观察时长、供应商确认音频/Token 单位分别记录。估算金额保存单价版本，可信结算到来后替代对应估算，不重复累加。没有结算证据时显示待结算，不把未知当作零。删除练习不返还已发生的调用额度；最小账本建议自调用发生起保留 90 天，仅保留必要计量、来源及去重字段，不存用户原话。此期限可评审，不是供应商账单保留政策。

**直接媒体连接的关键限制：** 代理 SDP 后，业务后端可能不再位于媒体或模型控制路径上。后端宕机、撤销本项目登录凭证或标记额度耗尽，都不必然关闭已经建立的供应商连接。客户端计时、心跳、关闭回调、令牌的建连有效期也不自动等于已连会话最大寿命。修改客户端还可能绕过本地停播和计时。

只有以下至少一条经过官方资料与实测确认，才可对相应边界承诺服务端强制结束：供应商提供可由本后端调用且有效的会话终止接口；服务端签发并由上游执行不可延长的会话 TTL/最大用量；或服务端持有必须经过的上游连接并能切断它。即使可终止，也需计入延迟上报、终止传播及供应商计费粒度，不能无条件承诺金额绝不超出。

占用退出与金额硬上限分开验收。正常试用的候选必须具有可验证的退出路径，覆盖信令答案丢失与客户端消失；无此能力仅可用于另行授权的受控选型实验，不能因用户接受软额度就无证据释放unknown。可靠终止仍可能存在传播和计量误差，是否接受没有金额硬上限继续作为明确选型决定。若硬上限必需，须选具备相应控制证据的路线；数据库quota字段不替代这些能力。

同样，前端转发的 usage 事件可能被修改或漏报。没有供应商服务端回调/账单查询时，不把它当成对抗滥用的可信扣费依据。供应商总账单与内部用量需可对账；失败建连和重连期间的未知消耗单独保留。

## 14. 候选供应商与有条件的替代路线

| 路线 | 当前判断 | 进入下一阶段的条件 |
| --- | --- | --- |
| 千问北京 WebRTC，当前浏览器原生适配 | 第一轮候选，尚未集成；原生恢复时评估flutter_webrtc | 当前Web支持范围内的双向音频、自然插话与文字收尾、已播放上下文、可信占用退出及用量边界均有证据；恢复原生交付时另验 |
| 国内托管 RTC / 对话引擎 | 条件性替代，未选定厂商 | 直接 WebRTC 的设备、弱网、打断或强制控制不满足要求时评估；核查国内实际区域、模型、服务端终止、计费和许可 |
| Flutter + LiveKit/Agents + 国内模型 | 条件性替代，增加媒体运行组件 | 需要服务端持有媒体/上游、可观测播放或更强控制，且接受额外运维和部署成本时再评估 |

官方 Realtime 概览列出多个协议和模型系列；最终型号、价格、权限和限流需要在实际账号中核对，本文不锁定一个未经验证的型号。[Realtime API 概览](https://help.aliyun.com/zh/model-studio/realtime-api-overview)

供应商评估记录必须包含模型/区域/版本、设备与网络、轮次策略、打断/截断能力、上游终止与 TTL、可信用量来源、数据留存以及实际账单。自然度、接话和打断质量的判定统一使用验证文档；先得到实际结果，再决定是否满足用户目标及可接受费用，不能预先写预算可控。

替代路线在一次练习之间切换，不在通话中无提示跨供应商迁移。保留相同业务会话和适配事件，但重新建立连接并重建有限文本上下文；音色、延迟和上下文可能变化。LiveKit 路线若引入独立媒体运行时，应重新评审部署图；“一个业务后端”仍成立，但不能把新增媒体组件隐去。

## 15. 开源证据能支持什么

[Nia 的固定源码快照](https://github.com/bielcarpi/nia/tree/9a97e911075c7740e6c5c2b8bf46e1002fc2070d)提供 Flutter、WebRTC、独立偏好、会后反馈和私人历史的可读实现；[实时客户端](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/mobile/lib/realtime/realtime_client.dart)、[服务端凭证与提示词](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/api/internal/provider/openai/client.go)和 [BSD-3-Clause 许可证](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/LICENSE)已检查。它支持本设计借鉴业务闭环与边界划分，不证明本项目选定供应商的全双工、费用或可靠队列已经实现。

Nia 默认 demo 是脚本会话；其 OpenAI/Firebase/Go 接法也不等于本项目要采用同一后端。uiniq 可参考国内服务与评测思路，但录音回合提交不能替代本项目自然全双工验收；Agora Flutter quickstart 可参考 RTC/VAD，实际默认区域及模型需另查。详细证据统一保留在[调研记录](../research/2026-10-15-product-and-stack-review.md)，不把示例仓库当作生产就绪证明。

## 16. 待协调的决定与开发前门槛

1. Flutter与产品范围已确认；Riverpod、路由、后端、数据库及邀请/用户名密码认证已工程采用，按基础决策和账号契约执行，不重复标为未选定。
2. D13、D17–D20已确认并有具体收尾/反馈/一级重练及删除规则；后台策略、原始音频及保留期限仍按总纲各自状态处理，不把本次完善扩大为全部数据政策的逐项批准。
3. 正常试用必须先证明旧连接可安全退出；金额硬上限、预算与实际模型权限继续在付费试验前明确，当前不开放准入。
4. 验证取消、输出清空、最后一句收尾、版本绑定的播放前缀与上下文修正；按钮取消不替代自然插话，缺失供应商能力不得写成已支持。
5. 按当前Web支持范围验证实际大陆网络、外放/耳机、权限、自动播放、后台与恢复；原生恢复时补验，质量与收尾矩阵由验证文档统一维护。
6. 在对应实现前按本次集中契约拆分任务；当前进展与授权仍以最新用户指令和HANDOFF为准，不将文档完成当作功能验证。


2026-10-21补充恢复入口的[保存/核验读取](2026-10-21-practice-finalization.md#7-恢复入口的保存与核验读取)：单SQL原连接termination-check只读端口；客户端严格验证当前或历史origin，两份状态在总八秒内原子发布，账号/404清除且不暗中写入。缺口分组显示、真实blocked待维护提示和准备清理门已接入原页面，仍不提供供应商终止执行器或完整历史。[本轮实测](../development/2026-10-21-saved-status-recovery-verification.md)。


2026-10-21[复盘输入与引用门](2026-10-21-review-inputs.md)新增独立ReviewInput投影，绑定原sealed input与policy/hash，原completion不改写。POST本人精确生成/重放、GET纯读；bodyless refs与源payload/member/global摘要链重新核对，0–3项内部输出只接受原用户版本与精确引用。缺质量信号不填分；上下文按scope限制，不把AI生成文字当用户目标。此为后续反馈任务基础，无新模型或页面；[本轮验证](../development/2026-10-21-review-input-eligibility-verification.md)。

### 已封存文字投影与建议定位（2026-10-22）

新增[本人sealed已保存文字契约](2026-10-22-saved-transcript.md)：GET saved-transcript复用完整源payload/member/global和有效result/quote门，32成员/8192源事件/4MiB范围内按scope/话轮分页，每页16、响应512KiB。普通回看不依赖ReviewInput/Job；focus绑定原item/连接/用户话轮/修订，不以同turn UUID或文本相似度选句。旧空修订、无转写revision0、AI旧prefix/当前生成文字与撤销分别处理，GET零业务写/媒体/模型调用。

客户端新增独立普通/定位阅读网址、严格页模型、初读来源+页共8秒及分页各8秒，单页内存、身份/迟到清理、分页网络失败保留原页；返回保留建议位置。ApiClient只增加默认不启用的实际响应字节上限，原review生成门保持。代码、自动检查、真实HTTP/wire与组件渲染已有证据；实际浏览器/Preview因Work设置禁用待补。[本批验证](../development/2026-10-22-saved-transcript-verification.md)。真实语音/模型、一级重练、完整历史/删除及完整学习闭环仍未完成。


### 2026-10-22 一级重练后端准备

[一级重练契约](2026-10-22-rehearsal-preparation.md)已将有效ordinary来源的完整原话/精确引用/安全前文派生为有界目标，确认hash后原子创建独立PracticeSession，子目标复验固定快照及当前来源，同级列表按父来源seek。迁移1a6de74c9f20增加kind与来源/目标字段、同账号ordinary父复合FK及部分分页索引，保留历史普通数据；非空重练拒绝降级。原普通准备digest不改，共同构造不提交，新包装一次提交；同key不重新准入，新的同级记录仍过占用门。

本批仅后端，默认Unavailable；未实现客户端重练确认页、正式媒体及原意/目标双维度评价，数据库级联不等于删除产品流程。真实HTTP/迁移/数据库约束与检查见[本批证据](../development/2026-10-22-rehearsal-preparation-verification.md)。前批文字页面的实际浏览器/Preview验收继续待补。


## 本人历史列表与详情工程接入（2026-10-23）

[本人历史契约](2026-10-23-practice-history.md)新增独立只读摘要前缀及owner/time/id索引，不改原普通准备和文字/复盘接口。Flutter增加账号绑定有限页、8秒/单飞/取消、分页保留与失效清空，接`/history`及详情并复用既有阅读页；列表不加载原话或调用模型。[证据](../development/2026-10-23-practice-history-verification.md)覆盖实际三页、跨账号、重启、19表零写入和迁移；实际浏览器/Preview仍待补，删除及真实媒体/反馈后续交付。


## 本人记录删除工程接入（2026-10-23）

[删除契约](2026-10-23-practice-deletion.md)采用User锁串行完整成员范围复验、内容清除/可见性墓碑及持久原key凭据。PracticeSession和连接最小安全状态独立保留，unknown仍阻止新建；两账本正文/固化快照/复盘输入任务结果/重练目标清除，晚到结果不能重建。Flutter接独立确认页、默认保留、8秒含CSRF与未知核对/原请求重放、旧provider清理和列表刷新。迁移3e5947bc0d21非空墓碑/凭据拒降；[证据](../development/2026-10-23-practice-deletion-verification.md)覆盖真实HTTP/重启/零复写及原开发数据保留。浏览器/Preview待补，真实终止/供应商删除仍待后续；备份重放最新进展见下节。

### 独立删除清单与离线恢复工程进展（2026-10-23）

[恢复契约](2026-10-23-deletion-restore.md)新增既有CLI导出/默认预检/明确目标库原子重放。4f6a58cd2e32持久化完整成员、保留旧备份缺账号/成员的删除决定；不补造数据，恢复后可继续导出。实际pg_dump/pg_restore完整及更早备份、缺账号再导出、HTTP旧正文404和unknown占用已验；API709、迁移/非空拒降及开发20表全行不变见[报告](../development/2026-10-23-deletion-restore-verification.md)。仅人工停服和可信最新清单前提下有效，自动备份、异地实时日志、保留期执行及费用/供应商终止仍待后续。

2026-10-25补齐[人工备份包](2026-10-25-backup-bundle.md)：`backup-create`在同一REPEATABLE READ READ ONLY快照生成PG17 custom dump和完整删除清单，私有排他目录、受限工具阶段和最后发布的manifest；`backup-check`只离线检查权限/文件/摘要/清单语义，不读Settings或建数据库。真实恢复及快照后删除另行重放已覆盖，见[验证](../development/2026-10-25-backup-bundle-verification.md)。包内清单不代表最新权威清单，完整性不代表可恢复；自动调度、异地实时清单及保留期执行仍未实施。

### 一级重练客户端目标与准备（2026-10-23）

[客户端契约](2026-10-23-rehearsal-client.md)复用现有四个后端端点中的source/child目标和独立创建，增加严格不可变目标/完整回复比对、owner fork/8秒单飞、固定未知请求与安全discard。ordinary资格独立GET核对，child只读；未设偏好保留阅读但先引导设置。无新连接或媒体、无后端/schema/依赖变化。[验证](../development/2026-10-23-rehearsal-client-verification.md)含真实Dart→HTTP、原key丢回包/两次同级及源失效，真实语音/改善评价仍缺。

### 关联重练列表客户端（2026-10-23）

[列表契约](2026-10-23-related-rehearsals.md)接通既有同级GET：owner/parent绑定、严格倒序和本地跨页锚校验、8秒单飞/取消、网络保留原页与确定失效清空。独立路由/provider/View及普通详情入口，原子只读，无后端/schema/依赖变动。[验证](../development/2026-10-23-related-rehearsals-verification.md)区分纯GET零写、专属夹具显式删除测试、组件渲染和实际浏览器待补。
