# 英语口语陪练：产品、开源代码与技术方案调研

调研日期：2026-10-15（中国标准时间）。这是供选型讨论的调研记录，建议部分尚待产品和技术验证后定稿。

后续产品决策统一见[产品与决策总纲](../superpowers/specs/2026-10-15-simontalk-mvp-design.md)。轻量语音伙伴方向已经确认；本文中的技术栈、导航和呈现细节仍为建议，不因列入调研而自动成为已批准方案。

已确认目标：你和几位朋友在中国大陆使用；首期只练英语日常交流；Flutter 覆盖手机 App 与 Web；实时语音、自动接话、允许插话；每人独立难度；对话结束后集中反馈。

证据范围：商业产品使用官方产品页、帮助文档、工程文章和公开截图；GitHub 项目检查实际依赖、实现代码及仓库图片。商业产品的完整客户端和后端栈通常不公开。以下“未确认”表示本次没有找到可靠公开证据。此次为资料与源码审阅，尚未安装登录商业 App，亦未进行真机通话、延迟或学习效果测试。

**商业产品：功能方向和页面设计。**

| 产品 | 主要方向 | 页面与交互观察 | 对本项目的启发 |
| --- | --- | --- | --- |
| Speak | 表达学习、开口练习、情境运用与个性复习形成闭环 | 官方展示以浅色背景、大卡片组织课程；有教师视频、突出显示的目标句型；对话使用气泡，在具体话语中展示表达反馈。完整底部导航本次未确认 | 日常聊天可以带一个轻量目标，复盘再把弱项变成下次练习 |
| ELSA Speak | 发音、清晰度、个性路径、角色扮演与进度 | 2026 新版明确四个底栏：Coach、AI Chats、Discover、Progress。公开截图使用蓝紫色视觉；AI Chats 有推荐、随机、自建场景，卡片带难度和预计时长 | 场景选择应让用户理解难度与时长；练习与进度可以分开组织 |
| Praktika | 人格化 AI 导师、个人学习计划、自由聊与情境练习 | 公开截图以白底、紫色按钮和大面积人物形象建立陪伴感。Practice 页有 Discussion、Roleplay、Debate、Interview，场景卡及 Start free talk；底栏为 Lessons、Practice、Dictionary、Profile | 人物有助于形成产品性格；直接开始自由聊的入口可以和场景库并存 |
| Loora | 成人自然英语长对话、场景练习与纠错 | 官方交互说明用下划线标语法、高亮标发音，点击后查看解释；每节少量口头纠正，结束后再看完整总结。公开反馈图有分组、高亮与跟读入口；完整导航未确认 | 保持聊天节奏，复盘聚焦少数关键表达；可把文字解释和重新开口连接起来 |
| TalkAI练口语（深圳小惊叹，App Store ID 6447748874） | 大陆用户的数字人视频/语音陪练、多难度、示例回答、生词本 | 官方截图首页为浅色背景、外教大卡、绿色开始按钮、工具与统计入口；对话为灰白/绿色气泡，中英内容和语法纠错卡结合 | 中文辅助和“卡住时给例句”适合初学者；本项目仍采用已确认的会后集中反馈 |

这些是公开页面与截图观察；版本、地区和账号差异可能改变实际界面。TalkAI 与同名 TalkAI Tutor、HelloTalk 的其他产品有区别，本表仅指上述 App Store ID。

产品与界面证据：

- [Speak 产品与公开界面](https://www.speak.com/)
- [ELSA 新版导航与截图（2026-01-04）](https://blog.elsaspeak.com/en/discover-the-new-elsa-speak-experience/)
- [Praktika 官方产品页](https://praktika.ai/)
- [Loora 官方学习流程](https://www.loora.com/support/getting-started/what-is-loora)、[纠错交互](https://www.loora.com/support/features/feedback-and-corrections)
- [TalkAI 官网](https://ttalkai.com/)、[官方 App Store 页面](https://apps.apple.com/cn/app/id6447748874)

可直接比较的公开界面图片：

- [ELSA：学习路径](https://i0.wp.com/blog.elsaspeak.com/wp-content/uploads/2026/01/LP.png)
- [ELSA：AI Chats](https://i0.wp.com/blog.elsaspeak.com/wp-content/uploads/2026/01/Untitled-design-3.png)
- [Praktika：Practice 场景与自由聊](https://praktika.ai/assets/step-5--dq0P3QK.webp)
- [Loora：反馈面板宣传图](https://www.loora.com/legacy/exp_02_device.webp)
- [Speak：对话中反馈宣传图](https://cdn.prod.website-files.com/61a88c135006e8345b005efd/6a0cb0b8f5349546e5f9a6fc_feature-3.png)

**商业产品：可以核实的技术栈。**

| 产品 | 公开证据能确认的技术 | 证据不足的部分 |
| --- | --- | --- |
| Speak | 官方工程文章明确 WebRTC、LiveKit Cloud、LiveKit Agents，以及多区域 Kubernetes；按功能混用 ASR→LLM→TTS 与语音到语音模型 | 客户端是否 Flutter、完整业务后端语言与数据库未确认 |
| ELSA | 自有语音/NLP 引擎、面向多口音的 ASR，以及 LLM 和检索服务 | 当前客户端框架、后端语言、数据库和全部模型供应商未确认 |
| Praktika | OpenAI 官方案例确认 GPT 系列、转写 API、多代理及持久记忆层 | Avatar 渲染引擎、完整客户端框架和后端基础设施未确认；招聘 Flutter 岗位不足以证明整个 App 采用 Flutter |
| Loora | 官方表示使用针对英语学习者优化的 LLM 系统和语音识别 | 具体模型、RTC 协议、客户端框架、后端栈未确认 |
| TalkAI练口语 | 官方功能与版本说明可确认数字人及对口型产品能力 | 模型、ASR/TTS 供应商、客户端框架和后端栈未确认 |

技术证据：[Speak 官方工程文章（2026-03-24）](https://www.speak.com/blog/building-speaks-voice-agent-platform)、[ELSA 官方技术说明](https://elsaspeak.com/en/efficacy)、[Praktika 官方技术案例](https://openai.com/index/praktika/)、[Loora 官方介绍](https://www.loora.com/)、[TalkAI 开发者说明](https://apps.apple.com/cn/app/id6447748874)。

由此得到的设计判断：英语学习者会停顿和组织句子，接话判断需要针对其实际行为调整。我们的“基础/进阶/熟练”除了词汇、句长和语速，还应影响等待用户继续说话的策略。这个策略应在不同水平用户的实际对话中测试，不能用一个静音阈值替代全部体验验证。

**GitHub：三项最有参考价值的公开代码。**

| 项目 | 实际技术栈 | 功能与页面 | 适合参考的部分和局限 |
| --- | --- | --- | --- |
| Nia | Flutter、flutter_webrtc、Go、Firebase Auth/App Check、Firestore、OpenAI Realtime，Cloud Run 部署配置 | 用户难度/话题/纠错偏好、会话、会后反馈、私人历史；截图为米白底、深绿气泡、顶部状态、底部输入；复盘是优点、原句/改句/解释、下一步和转写 | 与本项目闭环最接近；默认演示对话是脚本，真实服务接法存在代码但本次未做通话验证；大陆部署需重新选依赖 |
| uiniq | Next.js 14、React、TypeScript、Tailwind、FastAPI、SQLAlchemy/Alembic、PostgreSQL/SQLite，另有 Redis/arq；豆包 LLM、火山 ASR/TTS、腾讯口语评测 | 场景、语音练习、会后报告、历史与进度；页面源码含 Topics/History/Progress/Settings 和声波球、转写及反馈面板；本次线上演示不可访问，页面描述来自代码 | 国内 AI 服务接入和反馈流程值得学习；音频回合提交与分句播报，点击取消来接话，不能当作已验证的自然全双工实现 |
| Agora Flutter Quickstart | Flutter、agora_rtc_engine、agora_rtm、Node.js、agora-agents、agora-token | 连续收发语音、转写、智能体状态、通话控制；仓库截图是技术诊断式界面 | 适合研究实时媒体与打断结构。没有完整学习业务；源码默认 Area.US，Deepgram→OpenAI→MiniMax，需另行调整大陆服务配置 |

Nia 代码快照：`9a97e911075c7740e6c5c2b8bf46e1002fc2070d`，main 最近提交 2026-07-16。实际有 BSD-3-Clause LICENSE。主要证据：

- [仓库](https://github.com/bielcarpi/nia)
- [Flutter 依赖](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/mobile/pubspec.yaml)
- [Go 依赖](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/api/go.mod)
- [实时客户端](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/mobile/lib/realtime/realtime_client.dart)
- [服务端会话凭证与 VAD 配置](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/apps/api/internal/provider/openai/client.go)
- [会话演示截图](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/docs/assets/product-session.png)、[会后反馈截图](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/docs/assets/product-feedback.png)
- [许可证](https://github.com/bielcarpi/nia/blob/9a97e911075c7740e6c5c2b8bf46e1002fc2070d/LICENSE)

uiniq 代码快照：`d619127bac352828ed82016babad36d4e727ed98`，main 最近提交 2026-07-14。此次检查未发现 LICENSE/COPYING，源码复用许可待确认；现阶段作为实现思路参考。主要证据：

- [仓库](https://github.com/Zymonody7/uiniq)
- [前端依赖](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/frontend/package.json)、[后端依赖](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/backend/requirements.txt)
- [国内服务配置](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/backend/app/config.py)
- [录音回合提交](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/frontend/hooks/useRecorder.ts)、[取消逻辑](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/frontend/hooks/useChat.ts)、[分句语音输出](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/frontend/lib/speech.ts)
- [导航代码](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/frontend/components/uiniq/BottomTabBar.tsx)、[对话页面](https://github.com/Zymonody7/uiniq/blob/d619127bac352828ed82016babad36d4e727ed98/frontend/components/uiniq/Talk.tsx)

Agora 示例代码快照：`6b14bb98c1c16978e622d36a4d246a7633f10e83`，main 最近提交 2026-06-22。此次检查未发现 LICENSE/COPYING。它是接入示例；账号鉴权、用量控制等仍需业务后端实现。主要证据：

- [仓库](https://github.com/AgoraIO-Conversational-AI/agent-quickstart-flutter)
- [Flutter 依赖](https://github.com/AgoraIO-Conversational-AI/agent-quickstart-flutter/blob/6b14bb98c1c16978e622d36a4d246a7633f10e83/pubspec.yaml)、[Node 依赖](https://github.com/AgoraIO-Conversational-AI/agent-quickstart-flutter/blob/6b14bb98c1c16978e622d36a4d246a7633f10e83/backend/package.json)
- [RTC 收发](https://github.com/AgoraIO-Conversational-AI/agent-quickstart-flutter/blob/6b14bb98c1c16978e622d36a4d246a7633f10e83/lib/services/rtc_session_service.dart)
- [区域、模型与 VAD 配置](https://github.com/AgoraIO-Conversational-AI/agent-quickstart-flutter/blob/6b14bb98c1c16978e622d36a4d246a7633f10e83/backend/src/agent.js)
- [服务端路由](https://github.com/AgoraIO-Conversational-AI/agent-quickstart-flutter/blob/6b14bb98c1c16978e622d36a4d246a7633f10e83/backend/src/server.js)、[HTTP/CORS](https://github.com/AgoraIO-Conversational-AI/agent-quickstart-flutter/blob/6b14bb98c1c16978e622d36a4d246a7633f10e83/backend/src/http.js)

**建议采用的首版技术栈。以下为面向本项目的工程判断。**

| 层 | 建议 | 目的 |
| --- | --- | --- |
| 客户端 | Flutter / Dart | 同一产品覆盖 iOS、Android、Web，音频做平台适配 |
| 状态与路由 | Riverpod、go_router | 管理账号、会话状态、字幕、复盘与页面跳转 |
| 业务后端 | Python / FastAPI、Pydantic、HTTP API / OpenAPI | 一个服务集中处理账号、会话、记录和反馈 |
| 数据 | PostgreSQL、SQLAlchemy、Alembic | 保存每人的设置、会话、转写和复盘，管理数据迁移 |
| 实时媒体首轮候选 | flutter_webrtc + Qwen 实时模型的北京地域 WebRTC 接口 | 优先验证可减少中间平台的国内语音路线 |
| 建连凭证 | 业务后端代理 SDP 交换，供应商长期密钥只在后端使用 | 客户端得到会话连接结果；具体调用和会话约束在验证时确认 |
| 会后反馈 | 独立的文本模型调用与结构化结果 | 从转写提炼表达问题、中文解释和重练内容，与实时聊天分离 |
| 部署 | 单仓库、一个业务后端、Docker Compose、HTTPS 反向代理 | 适合小范围试用和后续迭代 |

Riverpod、go_router 是本项目建议，不能写成上述商业产品都在使用的技术。参考：[Riverpod 包](https://pub.dev/packages/flutter_riverpod)、[go_router 包](https://pub.dev/packages/go_router)、[FastAPI WebSocket 文档](https://fastapi.tiangolo.com/advanced/websockets/)。

语音路线的证据边界：[flutter_webrtc](https://pub.dev/packages/flutter_webrtc) 声明支持手机与 Web 音频、数据通道；[阿里云 Realtime API](https://help.aliyun.com/zh/model-studio/realtime-api-overview) 提供 WebRTC/WebSocket 等协议；[鉴权文档](https://help.aliyun.com/zh/model-studio/realtime-token-authentication) 允许服务端参与 SDP 建连鉴权。这些分别证明组件能力，尚未证明这一组合在我们的 Flutter 三端上已经跑通。模型型号、可用权限、英文质量、实际账单与设备兼容性在原型验证后锁定。

若需要更多媒体控制，可评估“Flutter + LiveKit/Agents + 国内模型适配”的路线；若优先采用托管通话引擎，可评估声网国内产品配置。前者增加媒体服务与运维，后者增加平台依赖和费用项目。当前首选先验证直接 WebRTC 接入，避免在测试前就增加媒体中间层。[LiveKit 官方快速开始](https://docs.livekit.io/agents/start/voice-ai/)

**建议采用的功能和页面骨架。**

底部导航为“练习 / 记录 / 我的”；通话与复盘作为单独的完整页面。手机端围绕快速开口设计，桌面 Web 使用适应宽度的内容区。

| 页面 | 首版内容 | 设计重点 |
| --- | --- | --- |
| 首次设置 | 邀请进入、个人账号、自选难度和兴趣 | 让不同水平用户快速找到合适起点 |
| 练习首页 | 显眼的开始聊天、少量日常场景、当前难度 | 自由聊入口优先，场景提供轻量交流目标 |
| 通话 | 伙伴形象或语音动效、当前听/想/说状态、可展开字幕、提示、静音与结束 | 语音为主；用户卡住时主动求助，纠错集中在结束后 |
| 复盘 | 有依据的鼓励、一个下次建议、零至三个表达改进、原句/建议表达/中文解释、重新开口 | 不凑数量，区分明确纠错和可选润色，每条反馈可定位到真实原话 |
| 记录 | 日期、话题、时长、复盘与完整转写 | 各自保留记录，便于回看和继续练 |
| 我的 | 难度、语速偏好、字幕/提示偏好、账号和用量 | 常用设置易于修改 |

本次“小范围使用”的含义是多人各自练习、各自保留记录；没有把社交群聊或共享个人对话加入首版。反馈以实际转写支持的语法和表达建议为主；音素发音分数需要额外音频评测证据与接入，宜作为后续独立能力评估。

已确认的整体方向是轻量语音伙伴。具体建议为浅色底、一个清晰强调色、少量场景卡、轻量伙伴形象和清晰字幕，细节仍待评审。它可以结合 Speak 的练习闭环、Loora 的聊天节奏和 Nia 的复盘结构；Praktika 的大人物和 ELSA 的完整学习路径作为比较参考，未纳入首版范围。

**下一步的验证依据。**

1. 按产品规格与建设路线推进；当前阶段、下一步和工作边界统一见根目录 [HANDOFF.md](../../HANDOFF.md)，不以本次调研日期推断后续实施进度。
2. 首个技术原型验证连续对话、不同水平用户的停顿、插话停止播放、扬声器与耳机、授权与断线状态。
3. 在实际大陆网络和目标设备上记录接话时间与失败情形，再选择供应商、模型和传输组合。
4. 语音路径成立后接入个人记录与复盘，使用同一批日常场景检查反馈是否具体、正确、可重练。

调研中没有进行生产通话质量或成本实测。商业产品宣传和仓库功能描述均不能替代上述验证。
