# Read-only Recovery Implementation Plan

> 使用superpowers:executing-plans在当前功能分支逐项执行，按持续授权直接开发；完成后使用requesting-code-review独立审查。无需重新确认工程选择，不推送/部署。

**Goal:** 用真实只读接口展示本人当前登记及原连接观测，不恢复或控制媒体。

**Architecture:** 严格分页模型/现有PracticeRepository读取；独立HTTP及账号作用域controller/provider；偏好页明确操作触发的纯视图。

**Tech Stack:** Flutter/Dart/http/Riverpod，沿用主题/Preview，无新依赖或后端迁移。

## Task 1: 原连接观测读取

- [x] 在`apps/client/test/features/practice/connection_observation_read_test.dart`先添加真实ApiClient/MockClient测试，运行`flutter test test/features/practice/connection_observation_read_test.dart`观察缺少方法失败。
- [x] 新增`lib/features/practice/connection_observation_models.dart`：固定身份/source、枚举/原因、严格范围/水位/游标/页大小、不变事件列表；在practice_repository.dart新增`loadConnectionObservations(ConnectionReservation connection, {int afterSequence = 0, int limit = 32})`，GET路径参数绑定并转稳定invalid_response。
- [x] 逐项验证空页/缺口、多页、错账号/连接/代次、重复/倒序、伪关闭原因、错总数/游标/类型均不被接受。

## Task 2: 生命周期与账号作用域

- [x] 先添加`practice_recovery_controller_test.dart`测试，再运行观察缺少controller失败。
- [x] 新增`lib/features/practice/practice_recovery_controller.dart`，接口`refresh()`、`loadObservations()`，提供busy/recovery/page/events/errorCode/observationErrorCode；操作串行且独立HTTP、8秒总截止/单调复核、取消与原账号检查；只接收当前操作结果。
- [x] 分页追加核对上次total/last不倒退、ID不重复；失败原游标重试、刷新清空，账号/401清除全部旧数据，销毁不再通知。
- [x] practice_providers.dart新增账号绑定`practiceRecoveryProvider`，构造不联网；补`practice_recovery_provider_test.dart`验证偏好/busy稳定、切换/退出销毁及进行中HTTP不使用新账号。

## Task 3: 可用视图与接入

- [x] 在`practice_recovery_panel_test.dart`先测试点击读取/只GET、空/错误/unknown与local_closed、显式分页/刷新及布局，运行确认缺少组件失败。
- [x] 新增`practice_recovery_panel.dart`的Consumer入口与纯PracticeRecoveryView，显式查看/刷新/查看更多/重新确认账号；preferences_screen.dart非引导接入；无麦克风/媒体依赖。
- [x] 增加浅色错误和深色200%字号预览，使用previewWithFonts；验证320/375/844/1024窗口、横屏/大字号/减少动画、按钮最小命中区及可达性。
- [x] 运行Flutter全量、分析/格式、Node、Web构建/字体、独立审查；修复确定问题，再核对真实本地只读空状态、更新交互/架构/本地开发/HANDOFF及验证证据后本地提交。

完成证据见[只读恢复验证](../../development/2026-10-18-readonly-recovery-verification.md)。
