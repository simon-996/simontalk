# Client Preparation Lifecycle Implementation Plan

> 使用superpowers:executing-plans在当前干净功能分支执行；用户已授权持续开发，不新增交互审批。按requesting-code-review派发只读复核。

**Goal:** 将现有准备/连接HTTP契约接入客户端，保护账号、幂等、业务租约和后台取消。

**Architecture:** ApiClient提供专用accountId/idempotencyKey参数；practice_models解析可信形状，PracticeRepository固定账号调用实际API，PracticePreparationController只管理未开始信令的连接；按账号绑定Riverpod与Flutter生命周期。

**Tech Stack:** Dart、Flutter、Riverpod、http、flutter_test；不增加依赖。

## Task 1: HTTP与类型

文件：`apps/client/lib/core/api_client.dart`、`apps/client/lib/features/practice/practice_models.dart`、`practice_repository.dart`；测试`apps/client/test/features/practice/practice_repository_test.dart`。

- [x] 先写请求头、默认503、身份切换、DTO非法组合/归属测试，运行`flutter test test/features/practice/practice_repository_test.dart`观察缺少实现失败。
- [x] 添加专用参数`request(..., String? accountId, String? idempotencyKey)`；前后检查账号，保留CSRF和现有账号流程，无自动重试。
- [x] 实现`createPractice/loadPractice/cancelPractice/createConnection/loadConnection/renewConnection/cancelConnection`，URI只用已验证UUID；创建payload固定free_chat或现有难度覆盖。
- [x] 严格解析服务端状态/快照和时间，返回不可变模型；仓库核对响应id/session/client/epoch及配置，跑定向测试至通过。

## Task 2: 生命周期

文件：`apps/client/lib/features/practice/practice_preparation_controller.dart`、`practice_providers.dart`；测试`apps/client/test/features/practice/practice_preparation_controller_test.dart`。

- [x] 先测`begin()`→reserved、重复点击仅一次、`retry()`复用两个创建键/原始payload、503无连接请求。
- [x] UUID使用`Random.secure()`的16字节，设置v4/version和variant；生成实例/创建键，不存长期密钥。
- [x] 控制器用generation隔离回调，保存原请求单调时间；15秒Timer发单个续租，单独截止Timer不会被在途请求延后。失败停止续租，不自动重建。
- [x] 先测后台/停止/销毁、晚到创建清理、续租慢响应/截止/重复计时；实现安全取消连接再取消练习。未知结果不发布stopped，已进入信令不调用准备取消。
- [x] 按登录账号创建provider，身份/生命周期变化停止实例；前台恢复不自动开始，provider销毁释放observer与timer。

## Task 3: 集成与证据

- [x] 执行`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`、`node --test test/web/*_test.mjs`、`flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000`与发布字体校验。
- [x] 独立静态审查并处理重要问题；真实本地HTTP拒绝结果与替身成功测试分开记录。
- [x] 更新API契约/本地开发、验证报告、HANDOFF；本地提交，不推送/部署。供应商及设备任务继续暂缓。

结果与剩余边界见[客户端准备验证](../../development/2026-10-17-client-preparation-verification.md)。
