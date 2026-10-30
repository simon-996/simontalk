# 千问播放复测探针（工具）

2026-10-30。为“修复后的生产传输脚本还没有在真实千问上复测”准备的受控实验工具。本环境无法直连外网、Chrome 也无法在此启动，因此工具只在本机做了服务端与静态检查，真实千问路径尚未执行——这不是复测结果。

## 1. 它解决什么

`apps/client/web/realtime_transport.js` 的播放修复只在本地双 Peer 回环里验证过（[音轨绑定](2026-10-30-webrtc-audio-stream-binding-verification.md)）。要在真实供应商上确认，需要浏览器、真实信令和真实音频同时在场。此前每次实验都要临时拼一个 Flutter 页面和替身服务，难以重复。

`scripts/qwen_playback_probe.py` 把这段固定下来：

- 本机静态服务，只绑定 `127.0.0.1`，页面直接加载仓库里的生产脚本 `/realtime_transport.js`，并打印其 SHA-256。
- API Key 只在服务端进程内使用；页面拿不到、日志不打印、回包不回显供应商错误正文。
- 一次运行默认只允许一次 SDP 交换（`--max-exchanges 1..3`），交换走的是后端同一个 `QwenWebRtcSignallingGateway` 类。
- 页面输入是 WebAudio 常量静音轨，不申请物理麦克风；输出元素静音。
- 观察项（`playback_playing` / `playback_waiting` / `playback_failed`、协议事件、交换结果）写进一份 JSON 证据，边界说明随文件一起落盘。

## 2. 怎么跑

```sh
cd services/api            # 复用后端依赖（httpx 等）
uv run python ../../scripts/qwen_playback_probe.py --port 7391
```

或从仓库根目录：

```sh
uv run --project services/api python scripts/qwen_playback_probe.py --port 7391
```

要求 `services/api/.env` 里有 `SIMONTALK_QWEN_API_KEY` 与 `SIMONTALK_QWEN_WORKSPACE_ID`（已有，脚本不读取其他配置）。启动后终端会打印模型、脚本哈希和证据路径，然后在 Edge 打开 `http://127.0.0.1:7391/`，点一次“运行一次”。

默认证据写到 `docs/development/evidence/<UTC日期>-qwen-playback-probe.json`；`--evidence` 可改路径。跑完先看这份文件，再决定是否保留和提交。

## 3. 页面做了什么

1. `window.simontalkRealtime.create()` 启动生产传输，`getUserMedia` 被替换为静音合成轨。
2. 交换回调 `POST /exchange`（`application/sdp`），服务端用真实网关换成 answer。
3. 收到 `session.created` 后发送受限 `session.update`（与 Dart 侧同一组字段：`modalities`、`max_tokens 128`、`enable_search false`、`voice Tina`、`turn_detection server_vad`）。
4. 收到 `session.updated` 后 `activate(channelId)`，再发一条文本用户消息与 `response.create`，要一句短回复。
5. 记录 `playback_playing` 等观察；`response.done` 后 2 秒或首次观察后 1.5 秒收尾，超过 45 秒强制结束。

## 4. 本轮验证（工具本身）

- `services/api/tests/test_qwen_playback_probe.py` 5 项：默认一次交换上限、超限 429、上游失败只回 `signalling_failed`/`APIError` 码、证据含脚本哈希与边界说明、页面确实引用生产脚本、两段内联脚本 `node --check` 通过。
- 实机启动服务：`/health` 200、页面内联脚本加载生产脚本、非法 offer 422、无外网时交换 502、第二次交换 429、`/evidence` 204 且 JSON 落盘。
- `ruff check` / `ruff format --check` 通过。

## 5. 边界（重要）

- **真实千问路径未执行**：本机浏览器无法直连供应商，Chrome 在此环境启动即报 `sandbox initialization failed`，因此页面未经真机渲染，`playback_playing` 从未在本轮出现。
- 探针只证明“生产脚本在这一浏览器里、这一次交换中是否报告了播放”。它不证明人耳听见、不证明文字与音频对齐、不证明上游已终止或计费停止。
- 页面用文本触发回复，不是真人语音；VAD、自然插话、多轮上下文都没有覆盖。
- 结论要以实际跑出的证据文件为准；没有出现 `playback_playing` 时，仍然只能写“未确认播放”。
