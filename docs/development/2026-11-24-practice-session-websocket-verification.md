# 正式练习页 WebSocket 媒体协调器与多轮播放结算验证

隔离入口挂载正式 `SimonTalkApp`，仅通过 Riverpod 显式注入 `createBrowserMediaSession` 与 `QwenServerMediaProtocol`，生产默认仍保持 `null` 与 `unavailableRealtimeProtocol` 关闭准入。协调器复用既有练习登记、连接预留、租约看门狗、观测账本、最终文字账本、播放证据账本及完成固化客户端，不创建 WebRTC 传输或发送 `/offer` SDP 信令，也不从客户端发送 `session.update`、`response.create` 或 `response.cancel`。

服务端消息泵（`QwenTurnPump` + `QwenTurnPolicy` + `WebSocketPcmRelay`）与浏览器音频路由（`streaming_pcm_output.js` + `streaming_pcm_sender.js` + `browser_media_session.js` + `QwenServerMediaProtocol`）通过显式播放结算帧 `{"kind":"settled","response_id":"..."}` 推进最多 64 轮对话：千问在网络侧提前发出 `response.done(completed)` 时不截断浏览器排队中的 Web Audio 分片，待该回复全部 `AudioBufferSourceNode.onended` 自然结束后才发送 `settled` 解锁下一轮；若用户在网络 `response.done` 之后、浏览器实际播完之前开口插话，服务端直接下发 `{"kind":"quarantine","response_id":"..."}` 而不误发上游 `response.cancel`，客户端立即停止剩余缓冲音频、保留插话转写并进入受控中断提示。全双工边界下 `settled` 与 `quarantine` 在途交叉时，双端收敛为隔离状态而不误判协议故障；Web Audio `onended` 仅用于推进轮次，不伪造 `PlaybackUpdate` 或 `DeliveryStatus.played`，助手播放证据保持 `unknown`。

| 检查 | 验证方法 |
| --- | --- |
| 准备交接与无 SDP 启动 | Chrome 从 `/practice` 点击“开始自由聊天 → 开始准备 → 进入通话”，预检记录安全取消后进入 `/practice/session`；信令网关计数为零，服务端仅执行一次 `session.update`，收到 `ready` 后才请求虚拟麦克风并进入“正在听你说”。 |
| 播放结算驱动的多轮对话与结束保存 | 首轮助手音频在 Chrome 自然播完触发 `onended` 并发出 `settled(response_a)` 后，第 2 轮用户转写触发服务端第二次 `response.create` 并播完 `settled(response_b)`（`starts=2, stops=0`）；页面渲染全部四条气泡，切换静音/开麦状态一致，点击“结束并复盘”后固化为 `completed` / `sealed`，PostgreSQL 按序保存 4 条 `FinalTranscript`，并可进入 `/practice/:id/save-status` 查看“这次练习的保存情况”。 |
| 网络已完成但浏览器仍在播音时的插话隔离 | 首轮下发 3 片共 2.25 秒 PCM 与 `response.done(completed)`，在 `settled` 尚未触发时注入第 2 轮用户语音；服务端零次 `response.cancel`、零次额外 `response.create`，立即下发 `quarantine(response_a)`，Chrome 同步停止未播完音源（`starts=3, stops>=2, settled=[]`），展示“对话已中断，暂时无法继续”与插话文字，结束固化保存 3 条 `FinalTranscript`。 |
| 中途离开页面 | 通话激活并发送首帧 PCM 后直接弹出通话路由返回准备页，麦克风轨道立即变为 `ended`、上游连接关闭，练习标为 `interrupted`、无 `PracticeCompletion` 记录，连接保持 `unknown` 与 `blocked` 终止核验。 |
| 协议、音频路由与交叉时序单测 | Python、Node 与 Flutter 单元回归覆盖 `settled` 校验、64 轮上限与 ID 防重放、`settled` 与 `quarantine` 在途交叉收敛、升级前/后取消差异、开麦前预置静音、收尾期尾帧接收及非法事件失败关闭。 |

复验步骤：在 `apps/client` 构建 `flutter build web --release --no-pub --no-web-resources-cdn -t test/web/practice_session_browser_entry.dart -o <临时输出目录>`，在 `services/api` 配置 `SIMONTALK_TEST_BROWSER`、`SIMONTALK_FLUTTER_SESSION_BUILD` 与以 `_test` 结尾的专用测试库，运行 `uv run --locked --no-sync pytest tests/test_flutter_practice_session_media.py`。

本轮检查结果：`dart format`（245 文件）与 `flutter analyze` 零问题；Flutter 全套测试 1,569 项通过、10 项专用夹具跳过（其中 `practice_media_websocket_session_test.dart` 10 项通过）；Node 浏览器测试 127 项通过；正式 Web 发布构建及 `check_web_fonts.py`（30,890 字符映射）通过；后端 `ruff check`、`ruff format --check`（166 文件）与 `alembic check` 通过；后端 WebSocket、千问策略、结束固化与 Chrome 联测共 614 项零跳过通过（含 8 项真实 Chrome + PostgreSQL 17 测试）。临时测试库与构建目录已清理，开发库未改动（`practice_sessions=0`），未调用真实千问模型、未推送或部署。

剩余边界：当前联测使用 Chromium 虚拟麦克风和本地千问事件替身；真实千问多轮与插话行为、物理麦克风/外放回声条件、插话后的已听前缀对齐与上下文安全恢复，以及可信远端退出核验与账单停费边界仍待实测，正式语音准入继续关闭。
