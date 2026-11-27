# 通话内「说慢一点」接入与验证

2026-11-25（Asia/Shanghai）

## 1. 功能边界与契约

按交互规格第 6.2 节与交接第 4 节，补齐通话内主动辅助的最后一项控件「说慢一点」：

- **仅限本场后续回复**：用户在 `active` 且未进入未知输出中断隔离的受控 WebSocket 通话中点击「说慢一点」，服务端将当前千问会话指令从正常语速切换为慢速清晰表达（`Speak slowly and clearly.`），作用于后续生成的 AI 回复；不会取消、截断或自动重播当前及既往回复。
- **不改个人默认偏好与历史快照**：本次操作不写回 `user_preferences.speech_pace`，也不改动 `practice_sessions.configuration["preferences"]["speech_pace"]` 初始快照；数据库无需新增迁移（Alembic `head` 保持 `19d7a3ec0b51`），运行期主管对初始快照的复核不变。
- **初始已慢速不重复发包**：若练习创建快照中的 `speech_pace` 已是 `slow`，协调器进入通话即标示「本场已放慢语速」（禁用态），服务端亦拒绝重复或已慢速连接再次发起调速。

## 2. 实现要点

- **服务端协议门禁与单次控制流**：
  - `QwenSessionGate`（`services/api/src/simontalk_api/qwen_websocket_session.py`）在保留本场难度、日常话题或一级重练提示、音色、模态、`max_tokens` 与服务端 VAD 参数的前提下，支持从已配置的 `normal` 会话生成至多一次 `slow` 版 `session.update`，并在 `accept_pace_updated` 中严格校验同一 `session.id`、全新 `event_id`、PCM 格式与慢速指令回显；重复请求、已慢速会话或回显不符均失败关闭。
  - `WebSocketPcmRelay`（`services/api/src/simontalk_api/websocket_pcm_relay.py`）在非收尾期仅接受一次精确 `{"kind":"pace","pace":"slow"}` 控制帧，纳入控制帧限流与配额。
  - `QwenSerializedSender`（`services/api/src/simontalk_api/qwen_outbound_serializer.py`）保持普通 `send` 拒绝 `session.update`，仅通过专用 `send_session_update` 允许单次会话指令更新排在待发音频之前，并在进入收尾停止新回复后丢弃未发更新。
  - `QwenTurnPump`、`QwenTurnPolicy` 与 `supervise_websocket` / `run_pump_session` 串联配置门实例：上游已进入插话隔离时忽略在途交叉到达的调速请求以保护尾句转写；校验通过后向浏览器下发 `{"kind":"pace_updated","pace":"slow"}`，不向客户端透传原始 `session.updated`。
- **客户端媒体桥、协调器与通话页**：
  - `streaming_pcm_sender.js`、`browser_media_session.js` 与 `BrowserMediaSession` 增加单次 `requestSlowPace()` 与 `pace_updated` 门控校验（未请求或重复推送均按协议异常关闭）。
  - `PracticeMediaController`（`apps/client/lib/features/realtime/practice_media_controller.dart`）维护 `SessionSpeechPace`（`normal` → `slowing` → `slow`），不调用 `holdPlayback` 或重播音频。
  - `PracticeSessionScreen` 与 `PracticeSessionView` 在主动辅助操作栏并列展示「说慢一点」/「正在放慢语速…」/「本场已放慢语速」，辅助面板展开时与「给我一个英文开头」「逐句翻译」同步收起，覆盖 320px 深色 200% 字号预览与布局测试。

## 3. 验证证据

- **真实千问单次零音频协议核验**：使用本机 `services/api/.env` 凭据经同域名 IPv6 连接北京地域 `qwen3.8-omni-flash-realtime` 一次，依次完成 `session.created` → 初始 `normal` 版 `session.updated` → 中途 `slow` 版 `session.update` / `session.updated` 校验；三次事件 `event_id` 互异、`session.id` 一致、`instructions` 原样切换为慢速提示、输入输出均为 `pcm`，随后本地 `1000` 正常关闭，零音频发送、零回复请求。
- **客户端与脚本测试**：
  - Node Web 脚本测试：`131` 项全部通过（含 `sendSlowPace` 与 `requestSlowPace` / `pace_updated` 新增用例）。
  - Flutter 全量测试：`1,604` 项通过（`10` 项隔离夹具跳过），`dart format --output=none --set-exit-if-changed lib test` 与 `flutter analyze --no-pub` 零问题。
  - Web 发布构建与字体检查：`flutter build web --no-pub --release` 及 `scripts/check_web_fonts.py` 通过（保留 `30,890` 项字符映射）。
- **后端、数据库与真实 Chrome 端到端联测**：
  - `ruff format --check`、`ruff check` 与临时 PostgreSQL 17 库上的 `alembic upgrade head` / `alembic check` 全部通过。
  - 后端 WebSocket 协议栈、数据库声明/主管、主动求助、本人用量及编译后 `SimonTalkApp` 的 7 项真实 Chrome 通话场景共 `208` 项测试零跳过全部通过。其中 `multi_turn_end_save` 在首轮回复播放结算后点击「说慢一点」，等待服务端确认并显示「本场已放慢语速」，再完成第二轮问答与封存，核实上游按序收到初始正常语速与中途慢速共 2 条 `session.update`（位于两次 `response.create` 之间）、首轮音频未重播或中断，且数据库中 `user_preferences.speech_pace` 与练习初始配置快照均保持 `normal`。
  - 临时测试库与临时 Web 构建目录已清理，开发库 `simontalk` 保持 `practice_sessions = 0`。

## 4. 未覆盖边界与下一步

- 默认生产保护未变：`main.py` 仍装配 `UnavailableAdmission`，`review` 与 `assistance` 提供方默认 `disabled`，客户端 `realtimeMediaSessionCreatorProvider` 默认 `null`、`realtimeProtocolFactoryProvider` 默认 `unavailableRealtimeProtocol`。
- 本次真实千问仅做零音频配置切换回显验证，Chrome 端到端使用虚拟媒体设备与本地千问协议替身；真实千问慢速指令在后续多轮语音中的实际听感语速差异、物理麦克风与扬声器回声/延迟、插话后的已听前缀续聊、可信远端退出及百炼账单核对仍待按交接下一步验证。
