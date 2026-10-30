# 本人练习删除实施计划

> 使用superpowers:executing-plans与test-driven-development顺序执行。持续开发授权已覆盖常规实现，不另开缺少未提交前置代码的worktree，不提交/推送/部署。

**Goal:** 本人历史详情可确认完整影响范围并真实删除正文，保留未知连接占用和无正文凭据。

**Architecture:** 用户锁串行范围变化/删除/原写入；墓碑+原子清除正文、持久幂等凭据；Flutter独立有界删除controller/page，复用原身份与CSRF。

**Tech Stack:** 现有Flutter/Riverpod/go_router、FastAPI/SQLAlchemy/PostgreSQL/Alembic，依赖不变。[规格](../specs/2026-10-23-practice-deletion-design.md)。

## 1. 后端范围与删除

- [x] 在`services/api/tests/test_practice_deletion.py`先写scope/DELETE/receipt真实测试，观察新路径404，再实现`practice_deletion.py`与`deletion_routes.py`注册main。
- [x] `models.py`新增deleted_at及PracticeDeletionReceipt；迁移`3e5947bc0d21`增加列/表，拒绝有墓碑时降级，避免静默恢复已删除内容。
- [x] scope先限定owner和deleted_at，再读取普通父/一级子，hash包含目标及排序成员ID；DELETE锁owner→成员→连接，重算后不一致409，保存原key/范围凭据与清除同事务提交。
- [x] 清除ReviewInput（级联job/result/action）、completion/member、两正文账本/观测、配置任意字段与重练目标；保留无正文attempt、连接及终止核验。安全准备关闭，上游未知保持unknown。
- [x] own_preparation及history/rehearsal列表排除deleted；旧创建key不可重放已删记录；原连接正文GET增加可见性核验。current保留最小安全状态并显示已删提示。
- [x] `pytest tests/test_practice_deletion.py tests/test_practice_history.py tests/test_review_worker.py`、Ruff/迁移metadata，随后全量。

## 2. Flutter删除与详情入口

- [x] 在`test/features/history/practice_deletion_test.dart`先写严格owner/id/key/hash/计数、只GET读取及固定DELETE/重放、超时/账号/迟到回归，观察缺文件RED。
- [x] 新增`deletion_models.dart`、`deletion_controller.dart`（scope/read/confirm/check/replay，8秒/单飞/独立fork），账号provider在`history_providers.dart`接入。
- [x] 新增`deletion_screen.dart`及`deletion_view.dart`，`app.dart`注册`/history/:sid/delete`并保留恢复地址。详情次级“删除记录”进入，保留/确认/核对结果清楚区分，成功invalidate旧历史后go列表。
- [x] scope变化废弃原确认、重新读范围；结果未知只显示原请求核对/明确重放；保留记录不发送DELETE。新增独立浅/深窄屏/大字预览。
- [x] 页面测试取消零写、完整数量、未知/冲突/成功返回、身份/离页，既有文字/复盘读取回归；恢复面板墓碑隐藏正文操作。

## 3. 验证与交接

- [x] 自动全量API/Flutter、分析/格式、Node、Web release/字体检查。
- [x] 专属临时库真实HTTP/Dart wire：范围变化、实际父/子删除、丢回包同key凭据、跨账号、unknown占用与正文零残留；开发库只schema升级并核对全行摘要。
- [ ] 可用时浏览器确认/取消/返回/深链接/键盘/窄屏及Previewer；不可用明确保留，不用样例渲染替代。
- [x] 请求独立代码审查（仅审查，不并行跑共享DB测试），修复后复验；清理临时进程/专属库/凭据/脚本；更新HANDOFF及各相关规格/报告。

实际工程与清理见[验收报告](../../development/2026-10-23-practice-deletion-verification.md)。浏览器/Previewer受Work设置禁用未执行，四态样例渲染及自动测试通过，实际点击待验。
