# 本人只读用量接口与界面验证

日期：2026-11-25（Asia/Shanghai）。在[逐回复语音用量落库](2026-11-25-voice-response-usage-verification.md)与复盘尝试记录基础上，接通本人只读聚合接口及前端查看入口；数据库 schema 保持 `56bd3c921ab4` 不变，未发起真实供应商计费调用。

| 检查 | 验证方法 |
| --- | --- |
| 账户与单次练习只读聚合 | PostgreSQL 17 集成测试（`test_owner_usage.py`）覆盖空账号零值、普通练习语音、一级重练语音、复盘尝试、缺失总量/分项计数（不冒充为零）、`unknown` 待核对连接计数，以及匿名 `401`、错配 `X-Account-ID` `409 account_changed` 和跨账号/不存在练习 `404 practice_not_found`。 |
| 删除正文后的无正文统计保留 | 删除父普通练习（级联清除一级重练正文与复盘任务）后，两练习的 `/v1/usage/practices/{id}` 均返回 `404`，而 `/v1/usage` 继续保留语音与复盘已知 Token 总和，准确递增 `deleted_practice_count`、`deleted_response_count` 与 `deleted_attempt_count`，且响应中不含已删练习 UUID、响应摘要或原话。 |
| 严格模型、静默构造与操作守卫 | Flutter 单测（`usage_models_and_controller_test.dart`、`usage_screens_and_previews_test.dart`）覆盖字段篡改拒绝、部分缺失总量兼容、单飞去重、8 秒超时清空旧快照、身份失效 `aborted`，以及 `/account` 与 `/practice/:id/save-status`（保持进入时仅 2 次既有保存状态 `GET`）在账号忙碌或切页后的旧回调零请求守卫。 |
| 组件预览与窄屏大字排版 | 4 组 `@Preview`（含删除与缺口、深色 `320` 宽 `200%` 字号、空态、单次练习用量）及保存情况页 `320` 宽 `200%` 字号渲染均无溢出或异常。 |
| 真实 Chrome + PostgreSQL 17 端到端 | `test_flutter_practice_session_media.py` 在双轮通话结束进入 `/practice/:id/save-status` 后点击“查看本次用量”，核验 2 次回复已知 `12/4` Token 与 1 次缺总量提示；再切换至 `#/account` 点击“查看本人用量”，核验普通练习语音统计与 1 条待核对连接提示。 |

本轮检查结果：`dart format`（254 文件）与 `flutter analyze` 零问题；Node Web 单元测试 129 项通过；Flutter 全套测试 1,579 项通过、10 项专用夹具跳过（新增 `test/features/usage/` 8 项）；正式 Web 发布构建及 `check_web_fonts.py`（30,890 字符映射）通过；后端 `ruff check`、`ruff format --check`（173 文件）与 `alembic check` 通过；后端用量、删除、历史、复盘及 Chrome 联测 116 项通过（2 项备份工具环境夹具跳过，5 项真实 Chrome 场景全通）。临时测试库与隔离构建目录已清理，开发库未改动（`practice_sessions=0`）。

剩余边界：界面展示的是服务端已入账 Token 统计，不等同供应商实际应付账单或远端会话已停费证明；百炼控制台账单核对、物理麦克风/外放回声与延迟实测、插话后的已听前缀/上下文续聊及可信远端退出仍待完成，正式语音准入保持关闭。[查询契约](../architecture/2026-11-25-owner-usage-read.md)
