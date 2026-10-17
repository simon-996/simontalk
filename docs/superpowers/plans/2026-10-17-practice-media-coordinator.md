# Practice Media Coordinator Implementation Plan

> 使用superpowers:executing-plans在现有功能分支执行；按用户持续授权直接落实设计，不另行确认。完成后使用requesting-code-review独立复核。

**Goal:** 将业务准备、一次性信令与媒体生命周期组合成默认关闭、可验证的正式客户端协调器。

**Architecture:** 独立PracticeMediaController直接使用现有Repository与RealtimeSignaller/Transport；协议通过明确端口注入，运行时默认拒绝。ConnectionLeaseWatchdog管理单调截止和串行续租定时，localClosed与服务端释放证据分开。

**Tech Stack:** Dart/Flutter、Riverpod、http、既有WebRTC JS桥接；无新增依赖或数据库迁移。

## Task 1: 端口、租约和基础流程

文件：新增`apps/client/lib/features/realtime/realtime_session_protocol.dart`、`connection_lease_watchdog.dart`、`practice_media_controller.dart`、`apps/client/lib/core/random_uuid.dart`；将原准备控制器UUID调用改用工具；ApiClient提供当前账号只读检查供Repository使用。

- [x] 先新增`test/features/realtime/practice_media_controller_test.dart`，覆盖503前不构造协议/信令/媒体、同一begin只登记一次、传输连接不等于配置就绪，运行该测试观察缺少实现失败。
- [x] 定义协议callbacks(send/confirmConfigured/fail)、channelOpened/receive/dispose和默认拒绝工厂；构造函数接收现有Repository及transport/signaller/protocol工厂。
- [x] 实现一次性创建、原key/客户端ID、独立租约watchdog；原准备控制器仅替换UUID工具，不接入媒体。
- [x] 通过测试确认原创建payload、账号绑定、初始45秒截止；begin等待只由active/localClosed结束。

## Task 2: 配置、回调和停止

同上控制器与测试，新增`test/features/realtime/practice_media_integration_test.dart`消费真实ApiRealtimeSignaller。

- [x] 先测start前/中早到通道事件、确认通道、activate晚到、60秒连接/20秒配置总限时；实现有限缓存和受保护协议回调；独立审查后新增单调阶段截止及两项先失败后通过的延迟回归。
- [x] 先测15秒串行续租、等待期间旧截止、晚到响应不能续命及unknown/终态关闭；实现同代次/配置/证据判断。
- [x] 先测后台、账号切换、dispose、重入监听器、传输关闭、协议错误、用户静音与播放恢复；实现同步本地释放和晚到丢弃。
- [x] 先测停止时创建晚到仅安全清理、信令前按连接→练习取消、信令后不发送准备取消；实现独立释放证据及共享清理future。
- [x] HTTP组合测试使用真实Repository/ApiClient/ApiRealtimeSignaller，验证offer账号/epoch及共享API存活，不调用供应商或物理媒体。

## Task 3: 账号作用域和交接

文件：新增`apps/client/lib/features/realtime/practice_media_providers.dart`及provider测试；新增架构/验证文档，更新技术设计、本地开发和HANDOFF。

- [x] provider只在signedIn时建立作用域，默认协议工厂Unavailable，不自动登记练习/交换信令或请求媒体；身份变化销毁旧实例。测试默认路径和处置。
- [x] 运行`flutter test --no-pub`、`flutter analyze --no-pub`、Dart格式、`node --test test/web/*_test.mjs`、Web release及字体；只读独立审查，确定问题先重现再修复。
- [x] 更新契约与真实测试证据、剩余供应商/观测/恢复/设备边界及下一步，本地提交，不推送或部署。
