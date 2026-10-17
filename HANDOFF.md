# SimonTalk 项目交接

最后更新：2026-10-18（Asia/Shanghai）。有实质进展时更新，并先核对实际 Git、文件和验证结果。

## 1. 一分钟理解项目

让本人和几位朋友在中国大陆，方便地开口练习日常英语。不同水平的人使用自己的难度与记录，和 AI 自然交流，结束后获得少量有依据的表达建议，并立即重新开口练习。

目标是由一名开发者维护、能长期使用的成熟产品。单仓库、逐阶段交付真实能力，不用草稿、假聊天、虚构记录或模拟成绩代替功能。

完整体验：自由聊天/话题 → 实时语音 → 自然插话/主动求助 → 会后复盘 → 逐句重练 → 历史回看。

## 2. 当前阶段与边界

**第2阶段账号/偏好、Web首屏与本机麦克风检查已实现；第3阶段准备/恢复/清理、代次/租约、WebRTC/Flutter桥接、单次SDP信令及独立媒体业务协调器已实现。本批新增受限client_observed持久观测、只读分页及媒体journal，观测不改变业务或终止证据。成功配置/媒体组合只用替身验证；此前真实浏览器合成回环证据保留。实际准入/网关/协议工厂均关闭，尚无恢复/练习页面、真实供应商语音或学习闭环；完整设备验收仍缺。**

用户已要求“开始吧”和多次“继续”，允许应用工程及本地验证。**2026-10-17最新指令：按照建议路线持续开发，不逐项汇报和确认；需要本人确认或更改的部分先跳过，待后续补齐后再实施。以Flutter Web为主，暂停Android构建和安装。** 常规可逆工程选择直接执行，验证与边界持续写入本文件；未提供的模型账号与预算不能由持续开发授权推定，付费连接仍关闭，不推送远端、不对外部署。物理设备许可、账号/预算及真实手机条件暂缓，不反复提问，也不阻塞其他工程工作。

| 项目 | 当前事实 |
| --- | --- |
| 仓库 | `/Users/simon/workplace/projects/simontalk`，origin为`https://github.com/simon-996/simontalk.git` |
| Git | main保留文档基线`71ecbe0`；当前`feat/account-foundation`，核对最新日志/状态；未推送 |
| 客户端 | `apps/client/`，真实账号/偏好；准备HTTP/信令前控制器、Web麦克风/WebRTC桥接、单次HTTP信令、独立媒体协调器/账号作用域及64条有界观测journal；原生工程保留 |
| 后端 | `services/api/`，FastAPI/PostgreSQL17/Alembic；账号、准备/恢复、代次/租约、周期清理与CLI、单次信令、受限观测追加/分页；真实语音准入与网关固定关闭 |
| 本地数据 | Compose专用数据库127.0.0.1:54329；开发库`simontalk`、独立测试库`simontalk_test` |
| 页面 | 深浅色、双弧线品牌、响应式表单、错误恢复；Web本机麦克风检查；没有练习占位页 |
| 检查 | 本轮后端192项、Flutter156项、Node51项；Ruff/分析/格式、两库Alembic、Web构建/字体和本地HTTP边界通过；独立审查未发现确定P1/P2，另重跑26项客户端定向通过；此前预览与合成回环证据保留 |
| 原生 | Android曾因磁盘不足构建失败，没有APK；已暂停并清理本轮新增资源。Android/iOS工程保留，均无设备验收证据 |
| CI | 已配置PostgreSQL/API检查、Flutter分析/测试/Web构建；APK步骤已移除，未推送、远端未运行 |
| 语音/学习 | 独立协调器已组合准备/信令/媒体端口及受限持久观测，协议默认拒绝、无页面；恢复消费、供应商语音/事件、反馈、重练、学习记录、用量与成本控制未实现 |
| 生产 | 没有线上服务；TLS、正式签名、备份恢复与运维待后续 |

启动、维护与检查见[本地开发](docs/development/local-development.md)，最新进展见[受限观测验证](docs/development/2026-10-18-connection-observations-verification.md)、[媒体协调验证](docs/development/2026-10-17-practice-media-coordinator-verification.md)、[单次信令验证](docs/development/2026-10-17-guarded-signalling-verification.md)、[恢复与自动清理验证](docs/development/2026-10-17-preparation-recovery-verification.md)、[客户端准备验证](docs/development/2026-10-17-client-preparation-verification.md)、[连接与租约验证](docs/development/2026-10-17-connection-reservations-verification.md)、[预览字体验证](docs/development/2026-10-17-preview-font-verification.md)、[WebRTC传输验证](docs/development/2026-10-17-web-realtime-transport-verification.md)、[准备登记验证](docs/development/2026-10-17-practice-preparation-verification.md)和[麦克风检查](docs/development/2026-10-17-microphone-check-verification.md)。账号基础、首屏/键盘和Android清理保留历史记录。

## 3. 已确认与工程采用

用户确认：少量朋友独立账号、中国大陆、暂时只支持英语日常交流、Flutter、自动接话与直接开口插话、独立难度、会后反馈、轻量语音伙伴、一个仓库与main、逐步做成正式产品。平台顺序已由Android优先更新为Web为主；原生工程保留，原生构建暂停。

| 内容 | 状态与说明 |
| --- | --- |
| Riverpod、go_router、http、flutter_secure_storage | 工程采用，版本以pubspec.lock为准 |
| Python3.13、uv、FastAPI/Pydantic、同步SQLAlchemy/psycopg、Alembic、PostgreSQL17 | 工程采用，一个业务后端 |
| 邀请码+用户名/密码 | 已实现；移动opaque Bearer安全存储，Web HttpOnly Cookie+CSRF；服务器存token摘要，Argon2id存密码 |
| 邀请72小时/重设15分钟/会话固定7天 | 工程参数，有事务并发与撤销测试 |
| 字体与渲染 | 原生系统字体；Web完整Noto Sans SC WOFF2约7.8MB、保留30,890映射/可变字重，注册前校验摘要；本地Roboto/CanvasKit；HTTPS或可信loopback |
| 实时语音 | 千问北京地域WebRTC仍为首轮候选；Web工程采用浏览器原生WebRTC与Dart桥接，原生恢复时评估flutter_webrtc；未接供应商或证明费用可控 |
| 音频/后台/删除 | 默认不保存原始音频、前台练习后台暂停、删除级联关联内容，仍按总纲建议状态推进 |

工程选择是在开发授权内沿用既有方案，不冒充用户逐项审批。决策见[产品总纲](docs/superpowers/specs/2026-10-15-simontalk-mvp-design.md)和[基础决策](docs/architecture/2026-10-15-foundation-decisions.md)，当前API以[账号契约](docs/architecture/2026-10-15-account-api.md)为准。

## 4. 下一步

1. 以Flutter Web持续推进：受限持久观测及媒体journal已完成，下一批接入只读恢复消费，补齐客户端观测读取模型和账号作用域恢复状态，再按真实数据接页面；读取不能接管、续租或释放其他客户端连接。unknown继续占用，local_closed不是confirmed终止。实际协议尚无实现，服务端信令成功仍只到configuring；不能把替身active冒充供应商就绪。未知创建key跨进程恢复与丢失答案后的可信终止仍缺。准入/网关/协议保持关闭；模型/预算/设备任务跳过，原生暂停。
2. 本地功能分支核对最新提交与干净状态，不擅自推送或部署；之后获推送授权时运行Web/API远端CI。
3. 应用内浏览器预检后传输异常本轮再次出现一次；明确重试后安全凭证提示、再次提交登录及退出成功。根因未确定，未调整CORS/CSRF、不自动重放，继续观察。
4. 待用户后续补齐账号/地域/预算与设备条件，再做物理麦克风及最小供应商语音闭环，实测插话、断线、释放、上游终止与计量，有证据后增加练习页。当前不主动索要重复确认，不把这些暂缓项冒充完成。

| 缺少输入或证据 | 影响 |
| --- | --- |
| 原生恢复时的设备与磁盘条件 | 当前已暂停；恢复后重新评估Gradle内存、下载空间、安装与音频体验，不作为Web前置。未接受的是microXR模拟器许可，并非本次手机构建的失败原因 |
| 模型权限/地域、预算及是否要求费用硬上限 | 付费调用与媒体路线准入；目前仅做准备 |
| 实际手机浏览器与版本 | 当前只有桌面浏览器视口/AX与widget证据；真实Android Chrome、需支持的Safari及辅助技术仍待验收 |

## 5. 七阶段状态

| 阶段 | 状态 |
| --- | --- |
| 1方案准备 | 工程前置落实；模型、费用与真机条件在对应任务前补齐 |
| 2工程底座 | 账号/偏好、首屏恢复、键盘选择与六项组件预览通过；Web性能与完整浏览器验收未完成，原生暂停 |
| 3真实语音 | 准备/恢复/清理、代次/租约、单次信令、Web底层、媒体协调/释放及受限持久观测已验证；配置/媒体组合仍为替身，协议/网关关闭；恢复页面、供应商语音/事件、费用和终止实测缺失 |
| 4学习闭环 | 未开始 |
| 5可靠性/成本 | 未开始 |
| 6Web交付与朋友试用 | 未开始；原生分发暂停 |
| 7成熟维护 | 未开始 |

完成标准见[建设路线](docs/roadmap/2026-10-15-product-roadmap.md)，不凭页面或文档标记整个阶段完成。

## 6. 必须保留的约束

- 自然插话必需，播放期间不能关闭上行伪装全双工；处理停播、上游取消和实际播放上下文。
- 临时字幕、最终用户话语、AI生成/播放文本分开。反馈引用可靠原话，零至三项，区分纠错与润色；无专用证据不输出确定的发音分数。
- 难度/语速用于新练习，历史保存配置快照；显示控制与按需翻译分开。当前偏好已保存，尚未接入模型。
- 重练独立记录/用量，不覆盖来源；删除后晚到任务不能恢复内容。
- 直连媒体在后端失联后可能继续计费，倒计时、撤销登录或数据库额度不等于上游终止/费用硬封顶。
- 不保存原始音频不代表供应商零留存；持久任务、媒体生命周期、隐私、成本及备份均需实测。
- 断网不误清登录；401才判失效。移动退出可先清本机；Web退出失败须保留真实Cookie状态。保存冲突不静默覆盖，多标签身份变化不自动重放旧操作。

## 7. 接手入口与最近工作

先读[AGENTS.md](AGENTS.md)与本文件，检查`git status --short`、`git log -3 --oneline`。没有`.codegraph/`时跳过CodeGraph，不擅自索引。

本批见[实施计划](docs/superpowers/plans/2026-10-15-account-foundation.md)，后续对照[交互](docs/design/2026-10-15-screen-and-interaction-spec.md)、[视觉](docs/design/2026-10-15-visual-design-spec.md)和[验证](docs/validation/2026-10-15-validation-plan.md)。本机已安装Flutter响应式/预览/布局排查与UI/UX Pro Max，另有design-taste-frontend；它们不随Git克隆自动安装，也不构成产品验收。

最近工作：按[观测计划](docs/superpowers/plans/2026-10-17-connection-observations.md)实现受限追加/分页及原连接身份复合外键；每批16条、每连接256条，完整重放成功、冲突整批回滚，历史/unknown只追加事实不改业务状态。客户端64条内存journal使用独立HTTP和8秒总截止，账号变化即中止；媒体停止先释放再上报，失败不阻塞。先失败后修复工厂内取消仍发送、延迟Timer接受超时确认两项回归。最终后端192、Flutter156、Node51项通过，Ruff/格式/分析、两库迁移检查、Web构建38.8秒及字体验证通过；独立审查未发现确定P1/P2，并重跑客户端定向26项通过。开发库添加性升级到f80e9c1a24bd，保持1账号/0练习/0连接/0观测；已重启本地API，readiness200、匿名观测401、超限413及响应保护实测通过。成功媒体路径仍为明确替身，观测source固定client_observed，不表示供应商就绪、可信终止或费用。未推送/部署，物理/模型任务暂缓，原生暂停。

后续交接更新完成内容/证据、剩余问题、可执行下一步、缺少输入和提交/推送/部署状态。用户最新指令优先，不沿用旧阶段边界。
