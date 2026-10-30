# 保存结果读取与历史入口实施计划

> **For agentic workers:** 按superpowers:executing-plans在当前会话逐项执行，持续开发授权已覆盖工程实现；完成当前项后立即推进下一项，不逐单元结束会话。

**Goal:** 本人能从任意历史练习查看真实保存阶段与具体缺口，纯读且与连接占用独立。

**Architecture:** 新controller复用HistoryRepository与SavedTranscriptRepository.readCompletion，2次GET共8秒，严格状态/coverage一致后原子发布。新Screen与View复用PracticeSaveStatusView，独立family由owner管理；历史入口和删除成功清理接现有功能。

**Tech Stack:** Flutter、Riverpod、go_router、现有FastAPI/PostgreSQL接口，无依赖/schema变化。

## Task 1：独立保存状态读取

- [x] 新建`apps/client/test/features/practice/saved_practice_status_test.dart`，先RED：构造静默、2次GET/固定owner、未登记404、ending/sealed/缺口、状态冲突、格式/外账号拒绝、单飞、总8秒、两步之间截止、dispose/身份变化清除与迟到不发布。
- [x] 新建`apps/client/lib/features/practice/saved_practice_status_controller.dart`。`refresh()`先清旧值，使用一个fork ApiClient和Timer/Future.any，执行detail→completion；未登记仅接受completion_not_found；两份status/coverage不一致抛`save_status_changed`。state与数据getter沿用owner门。
- [x] 运行目标回归，修到通过；记录真实结果后继续Task 2。

## Task 2：页面、路由与历史衔接

- [x] 新建`.../saved_practice_status_providers.dart`、`saved_practice_status_screen.dart`、`saved_practice_status_view.dart`和独立`..._previews.dart`，测试放对应`apps/client/test/features/practice/`。`PracticeSaveStatusView`用于保存内容，整次connection_pending另显示。初读/刷新/身份恢复/返回语义清晰；旧回调核对当前路由/controller/owner/busy。
- [x] `apps/client/lib/app.dart`注册save-status只读路由及恢复地址；`features/history/history_screen.dart/history_view.dart`增加详情入口；`deletion_screen.dart`可信receipt失效新纯读family。
- [x] 先RED新增Screen/入口/删除清理回归，再实现；覆盖未设难度、账号变化、断网清旧、返回、当前及旧按钮资格、320/375/横屏/200%/深浅色、Preview独立渲染。继续Task 3。

## Task 3：实际HTTP与完整验证

- [x] 专属`_test`库迁移，测试夹具真实封存和未登记记录；启动仅loopback默认关闭网关API。新增可选wire测试，Dart控制器实际读取、跨账号/删除失效/纯GET，全表全行前后对比；开发库只读快照并保留。
- [x] Flutter全量/分析/格式、Node桥接、Web release/字体；所有Flutter命令`--no-pub`。后端未改不把既往API720作本次重跑；wire与Widget区别记录。
- [x] 独立只读审查，必要问题先RED修复。同步交互/架构/验收/交接，检查文件摘要和链接；清理专属库/服务/凭证/脚本，不提交/推送/部署。
