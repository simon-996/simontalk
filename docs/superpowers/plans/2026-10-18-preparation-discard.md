# Preparation Discard Implementation Plan

> 使用superpowers:executing-plans逐项执行当前功能分支；按持续授权直接实施，完成后使用requesting-code-review独立只读审查。不推送/部署、不启用模型或原生构建。

**Goal:** 让用户明确、安全地清理尚未开始上游的准备登记，失败不虚构终止。

**Architecture:** 新的单事务expected_epoch清理用例/路由；既有恢复控制器新增有界明确动作；纯确认对话框接入偏好页。

**Tech Stack:** FastAPI/Pydantic、PostgreSQL17/SQLAlchemy；Dart/http/Riverpod/Flutter主题与Preview，无新依赖/迁移。

## Task 1: 单事务后端

- [x] 新建`services/api/tests/test_preparation_discard.py`，使用现有prepared/reserve夹具，先测POST不存在失败；运行`uv run pytest -q tests/test_preparation_discard.py`。
- [x] 新建`src/simontalk_api/preparation_discard.py`定义DiscardPreparationInput(expected_epoch)和discard_preparation；practice_routes.py新增`/{session_id}/discard-preparation`，Web写保护与locked_identity后调用。
- [x] 先验证完整历史、最新代次/安全证据，再一次提交连接closed与父cancelled；幂等返回原终态，409/404/422不写入。用快照验证unknown/历史/新代次及锁后身份不可改变。
- [x] 补并发重复、新连接、单次offer竞争测试，确认外部网关要么未调用，要么unknown被保留；全量后端及Ruff/格式/两库Alembic。

## Task 2: 明确客户端动作

- [x] 新建`apps/client/test/features/practice/preparation_discard_test.dart`，先测缺少repository/控制器方法；运行`flutter test test/features/practice/preparation_discard_test.dart`观察失败。
- [x] practice_repository.dart新增`discardPreparation(PracticePreparation original)`，固定账号/路径和expected_epoch，严格核对成功原身份/快照和安全取消结果。
- [x] practice_models.dart增加恢复候选资格getter；practice_recovery_controller.dart使用操作枚举串行刷新/观测/清理，传入弹窗原快照；增加PreparationCleanupStatus及状态码。复用独立HTTP和8秒截止，不自动重试。
- [x] 验证成功仅确认原对象；任何拒绝/未知结果清旧快照、刷新核实；切换账号、401、销毁/迟到、重复点击和超时均不追加新操作。

## Task 3: 页面与交接

- [x] 新建`preparation_discard_panel_test.dart`先验证候选按钮、弹窗取消无请求、确认POST及未知无按钮；补失败/大字号/横屏测试，再实现。
- [x] 新建`preparation_discard_dialog.dart`纯对话框/Preview，practice_recovery_panel.dart接入捕获的原快照及确认后动作，分别显示清理中/已确认/未确认/拒绝，不将成功伪装为空current。
- [x] Flutter全量/分析/格式、Node、Web发布/字体、对话框预览和独立审查；修复确定问题，更新接口/交互/本地开发/HANDOFF及验证证据后本地提交。

## 验证中追加

- [x] 真实浏览器发现清理后首次退出403，先补共享Cookie模拟失败测试，再共享ApiClient家族CSRF/pending，保留独立HTTP及账号复核；迟到拒绝回归先失败后修复。媒体组合夹具改为核对共享令牌，最终Flutter232项通过。
- [x] 独立测试库真实浏览器确认清理200、unknown并发409及观测、修复后首次退出204；仅清理本批夹具，开发库不种数据。
- [x] 独立功能审查与CSRF追加审查无确定P1/P2；22项定向另行通过。预览首次漏检，原生clean后冷启动发现10项并实际呈现新增两项；发布/字体/文档链接检查通过。

完整命令、结果及边界见[验证记录](../../development/2026-10-18-preparation-discard-verification.md)。
