# 一级重练实时语音接入与端到端验证

日期：2026-11-25（Asia/Shanghai）。在[一级重练准备契约](../architecture/2026-10-22-rehearsal-preparation.md)、[重练客户端准备契约](../architecture/2026-10-23-rehearsal-client.md)、[重练两轴评价](../architecture/2026-10-26-rehearsal-evaluation.md)与[正式练习页 WebSocket 会话](2026-11-24-practice-session-websocket-verification.md)基础上，打通一级重练从建议确认到 `/practice/session` 实时语音通话、独立封存、两轴重练评价与重练用量汇总的完整闭环。数据库 schema 保持 `56bd3c921ab4` 不变，正式语音准入保持关闭。

| 检查 | 验证方法 |
| --- | --- |
| 服务端重练声明与提示门控 | `verified_rehearsal_prompt`（`rehearsal_targets.py`）与 `claim_websocket`（`websocket_claim.py`）在事务锁内核验 `kind == "rehearsal"`、普通父关联、冻结 `rehearsal_target` 结构及 `rehearsal_target_hash` 摘要，篡改或失配在创建上游连接前以 `409 practice_configuration_changed` 拒绝。`QwenSessionGate`（`qwen_websocket_session.py`）将原句、关注片段与参考说法经有界截断与 JSON 转义嵌入重练伙伴指令（明确作为引用数据而非指令、鼓励自然表达原意不要求逐字背诵），并严格校验 `session.updated` 的逐字回显；运行期删除父普通练习级联删除重练记录时，`supervise_websocket` 守护立即本地断流并登记 `unknown` / `blocked` 核验。 |
| 协调器既有准备承接与预检取消 | `PracticeMediaController.begin(preparation: ...)` 直接承接 `created` 且 `connection_epoch == 0` 的独立重练准备，在原重练 `session_id` 上预留第 1 代连接，不额外创建或取消普通练习；若在 WebSocket 握手发起前取消，依次取消连接与原重练准备并记 `released`；对非 `created` 或 `epoch > 0` 的准备立即以 `preparation_state_changed` 本地关闭且零请求。 |
| 重练准备交接与路由守卫 | `/practice/:sourceId/rehearse/:itemId` 在准备登记成功（`created`、`epoch == 0`）后展示“进入重练通话”，点击复验当前路由、登录身份、展示目标与准备快照后携带 `RehearsalSessionLaunch` 进入 `/practice/session`。刷新页面缺失 `extra` 或携带其他账号 `RehearsalSessionLaunch` 时，路由守卫重定向回 `/practice`（未登录回 `/login`），不会误开麦克风或新建普通练习。 |
| 重练通话标识、窄屏布局与会后导航 | `PracticeSessionView` 在重练模式下展示“重练：这一句表达”标题、本次覆盖难度及紧凑的“重练片段 / 参考说法”横幅（深色 `320` 宽 `200%` 字号渲染无溢出），支持同套静音、插话隔离与有界收尾；封存后提供“查看重练评价”“查看本次记录”“回原复盘”“再练一次”“回到练习”，其中“回原复盘”固定指向来源普通练习，“再练一次”失效旧重练控制器并回到同来源同建议项重新核验创建同级新重练。 |
| 真实 Chrome + PostgreSQL 17 端到端闭环 | `test_flutter_practice_session_media.py` 新增 `rehearsal_end_save`：预置已封存普通练习与有效复盘建议 → Chrome 打开 `#/practice/:sourceId/review` 点击“练这一句” → 切换本次难度为“深入表达”（不改日常“轻松起步”）并确认准备 → 点击“进入重练通话” → 核对服务端发送含重练片段/建议与 `advanced` 提示的 `session.update` → 虚拟麦克风收发一轮语音并完成 Web Audio 播放结算 → 点击“结束并复盘”独立封存子重练（父普通练习保持 `completed` 且全库仅此 2 条练习记录） → 查看本次保存情况与本次语音用量 → 点击“查看重练评价”触发并读取两轴重练评价（“本次已传达原意 / 本次已展示目标表达”，且重练复盘页不暴露嵌套“练这一句”） → 切至 `#/account` 查看本人用量，核验“逐句重练语音”与“会后复盘与重练评价”Token 统计一致。 |

本轮检查结果：`dart format`（254 文件）与 `flutter analyze --no-pub` 零问题；Node Web 单元测试 129 项通过；Flutter 全套测试 1,589 项通过、10 项专用夹具跳过；正式 Web 发布构建及 `check_web_fonts.py`（30,890 字符映射）通过；后端 `ruff check`、`ruff format --check` 与 `alembic check` 通过；后端重练、WebSocket 声明/主管、评价、用量及真实 Chrome 全部 6 项语音场景共 202 项零跳过通过。临时测试库与隔离构建目录已清理，开发库未改动（`practice_sessions=0`）。

剩余边界：自动化联测使用浏览器合成音轨与千问 WebSocket 替身；物理麦克风与外放下的真实千问重练通话、首声/停播延迟与回声条件、插话后的已听前缀与上下文续聊、百炼实际账单核对及可信远端退出仍待实测验证，正式语音准入保持关闭。

2026-11-26 直接使用生产重练配置门接真实千问，两个合成语音样本均收到声音回复。其中只说“Could you help me say that in a more natural way?”的样本，回复使用了冻结目标中的篮球表达。物理设备和完整端到端重练验收仍待进行。[真实语音抽样](2026-11-26-websocket-output-clock-settlement.md#日常话题和一级重练的语音抽样)
