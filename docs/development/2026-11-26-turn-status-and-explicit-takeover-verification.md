# 受控 WebSocket 通话真实轮次状态与显式「我来说」验证

2026-11-26（Asia/Shanghai）

## 1. 交付范围与规格对齐

对应产品总纲 `D04`、交互规格第 6.1 / 6.3 节、视觉规范第 6 节与验证计划第 5 节，补齐受控 WebSocket 通话页的真实轮次/播报状态与显式「我来说」受控打断控制：

- **WebSocket 真实轮次与播报状态**：
  - 等待用户开口：开麦显示「正在听你说」，静音显示「麦克风已关闭」。
  - 用户有效发声中（话轮已建立且尚未收到最终转写，开麦状态）：显示「在听，请继续」。
  - AI 组织回答（用户最终转写已完成或 `response.created` 已到达、首片 Web Audio 尚未开始排程播报）：显示「正在想怎么回应」，并记录 `playback_waiting` 连接观测。
  - AI 播报中（Web Audio 首次排程音频分片至全部 `AudioBufferSourceNode.onended` 自然结束前）：显示「正在说」，记录 `playback_playing` 连接观测；期间静音不会停止已开始的 AI 播报，待播报自然结算回落 `idle` 后切换为「麦克风已关闭」。
- **显式「我来说」受控打断（与当前受限未知边界语音插话一致）**：
  - 在 AI 组织回答（`response.created` 已绑定）或播报期间展示「我来说」操作。
  - **静音保护**：当前处于静音时显示禁用态「我来说（先开启麦克风）」，客户端与服务端均禁止在静音态发起显式打断，绝不悄悄解除静音；用户主动打开麦克风后按钮立即恢复可用。
  - **即时停声与受控收尾**：开麦点击「我来说」时，浏览器同步停止本地 Web Audio 活动音源并发送单次 `{"kind":"interrupt"}`；服务端引退后续音频分片，对尚未 `response.done` 的回复并发发送 `{"type":"response.cancel"}` 与下游 `quarantine`（已 `response.done` 的缓冲播音期则不发多余 `response.cancel`），同时清空旧用户项绑定并保持麦克风继续拾音，接收并保存用户随后说出的一句原话。因千问部分播放前缀对齐与同会话上下文截断尚未验证，打断后沿用既有受控隔离状态提示结束保存，不伪造已截断续聊，也不以按钮打断替代自然开口插话验收。

## 2. 验证证据

- **静态检查与单元回归**：
  - Node Web 脚本测试：`133` 项全部通过（覆盖 `sendInterrupt` 静音拒绝与单次幂等、`playback` 三态事件流转、点击打断与服务端 `quarantine` 协同）。
  - Flutter 全量测试：`1,606` 项通过（`10` 项专用夹具跳过），`dart format --output=none --set-exit-if-changed lib test` 与 `flutter analyze --no-pub` 零问题，覆盖 320px 深色 200% 字号下「我来说」与「我来说（先开启麦克风）」无溢出渲染。
  - Web 发布构建与字体检查：`flutter build web --no-pub --release` 与 `scripts/check_web_fonts.py` 通过（保留 `30,890` 项字符映射）。
  - 后端检查：`ruff format --check`、`ruff check` 与临时 PostgreSQL 17 库 `alembic upgrade head` / `alembic check` 全部通过（无新增迁移，Alembic `head` 保持 `19d7a3ec0b51`）。
- **PostgreSQL 17 + 真实 Chrome 8 项端到端场景**：
  - 后端协议栈、数据库声明/主管、主动求助、本人用量及编译后 `SimonTalkApp` 的 8 项真实 Chrome 场景共 `213` 项测试零跳过全部通过。
  - `multi_turn_end_save` 验证了 `connection_observations` 持久记录 `playback_waiting` 与 `playback_playing`。
  - 新增 `explicit_takeover_interrupt` 场景在真实 Chrome 中验证：首轮 AI 进入「正在说」播报 → 点击「静音麦克风」出现「我来说（先开启麦克风）」且播报继续 → 点击「打开麦克风」恢复「我来说」 → 点击「我来说」立即停止本地音源、上游收到 1 次 `response.cancel` 并返回 `cancelled`、页面进入受控中断提示且麦克风继续拾取并封存第三条用户转写（`Let me take over`）。
  - 临时测试库与构建目录已清理，开发库 `simontalk` 保持 `practice_sessions = 0`。

## 3. 剩余边界与下一步

- 默认生产保护保持关闭：`UnavailableAdmission`、`review` / `assistance` 提供方默认 `disabled`、客户端 `realtimeMediaSessionCreatorProvider == null`。
- 点击「我来说」是与自然语音插话并存的显式控制，不能替代物理麦克风下的自然开口打断验收；打断后的已听前缀边界、同会话或新会话上下文续聊、物理设备回声/延迟、可信远端退出及百炼账单核对继续按交接下一步推进。
