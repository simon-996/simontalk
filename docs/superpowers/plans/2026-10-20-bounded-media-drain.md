# 有界媒体收尾 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 落实正常end的固定截止收尾、无文字输入登记及版本绑定的内存中断前缀。

**Architecture:** 传输负责同步停采停播；协调器冻结原集合并控制单调截止；投影只管理文字和设备输出依据。协议仍默认拒绝，后端和付费调用不变。

**Tech Stack:** Flutter/Dart、原生浏览器WebRTC与JS桥、flutter_test、Node test。

---

### Task 1: 内存前缀与开始登记

**Files:** `apps/client/lib/features/conversation/conversation_models.dart`、`conversation_projection.dart`；新增 `apps/client/test/features/conversation/conversation_output_tail_test.dart`。

- [x] 写失败测试：`p.apply(TurnStartedUpdate(...))` 后空用户可接final；`p.freezeResponse(responseId, stopBoundaryMs: 400, reason: InterruptedPrefixReason.interrupted)` 将可靠旧revision前缀保留为context，晚final不继承播放。
- [x] 运行 `flutter test --no-pub test/features/conversation/conversation_output_tail_test.dart`，确认缺少上述接口而失败。
- [x] 实现开始登记、单向item绑定、冻结/撤销、版本类型与容量原子限制。更换item或放大停止上限必须抛 `ConversationFailure`，unknown不生成前缀。
- [x] 重跑新测试及 `test/features/conversation/conversation_projection_test.dart`，检查不可变旧快照、clear、超量和晚版本。

### Task 2: 同步停采停播与原通道保留

**Files:** `apps/client/lib/features/realtime/realtime_transport.dart`、`realtime_transport_web.dart`、`realtime_transport_native.dart`、`apps/client/web/realtime_transport.js`、`apps/client/test/web/realtime_transport_test.mjs`、`realtime_bridge_test.mjs`、`realtime_bridge_entry.dart`。

- [x] 增加Node失败测试：`transport.beginDrain()` 后tracks已stop、audio已pause且断开，旧控制通道仍收事件/发控制，激活/恢复/晚track不复活。
- [x] 运行 `node --test test/web/realtime_transport_test.mjs` 确认缺少beginDrain行为。
- [x] 实现同步 `void beginDrain()`；JS返回错误码由Dart转换，native抛unsupported。drain仅原controlChannel可用，stop仍释放所有资源，异常逐项释放。
- [x] 重跑Node全套和实际Dart→JS桥编译，包含重复drain、迟到异步与stop。

### Task 3: 协调器和账号归属

**Files:** `apps/client/lib/features/realtime/practice_media_controller.dart`、`realtime_session_protocol.dart`、`connection_lease_watchdog.dart`、`practice_media_providers.dart`；`apps/client/test/features/realtime/media_fixtures.dart`、新增 `practice_media_drain_test.dart`、扩展 `practice_media_providers_test.dart`。

- [x] 先写 `final ended = controller.end(); expect(controller.phase, PracticeMediaPhase.draining);` 等失败测试，并验证同步停采、相同Future、3秒不可顺延、最后无字幕用户及AI收尾、假期满回调拒收、较早租约、后台/身份/销毁和队列finish时机。
- [x] 运行 `flutter test --no-pub test/features/realtime/practice_media_drain_test.dart`，确认缺少end接口而失败。
- [x] 新增 `end()`，冻结话轮/response，调用transport和protocol各一次；冻结截止/停止续租；协议普通发送被关闭，输入完成/原回复取消控制按类型和response去重。仅原通道原话轮final和播放证据可通过，每次入口先guard。
- [x] `ConnectionLeaseWatchdog` 提供只读deadline及只停renew的能力；在途续租不重置收尾租约。正常end独立于HTTP完成，stop立即完成end操作并保留上游unconfirmed。
- [x] 账号作用域保留已开始的收尾和journal，页面监听离开后仍运行；账号变化销毁。扩展provider测试实际撤掉最后监听再推进时钟，验证不会提前abort或借新账号补交。
- [x] 重跑新测试和所有realtime测试。

- [x] 独立审查回归：续租失败与在途播放draining结果不提前stop；原通道revoke清除无效前缀；`prepareContext → sendContextControl → confirmContextTruncated`必须绑定同一不可变token/原scope/channel/当前revision，确认后旧终态仍接收保存，已用依据失效则安全停止。运行`flutter test --no-pub test/features/realtime/practice_media_drain_test.dart`确认35项通过。
- [x] 确认释放回归：journal为Listenable，finish且queue空/最后ACK后清内部投影；provider动态keepAlive，无监听且localClosed/pending0时释放，active离页先stop，失败pending明确retry。运行`flutter test --no-pub test/features/realtime/practice_media_providers_test.dart test/features/conversation/final_transcript_journal_test.dart`。

### Task 4: 复核与交接

- [x] 独立规格审查，修正确定遗漏；随后独立代码质量审查并复查修复。
- [x] `flutter test --no-pub --reporter expanded`、`flutter analyze --no-pub`、`node --test test/web/*_test.mjs`、`dart format --output=none --set-exit-if-changed lib test`。
- [x] 使用原依赖 `flutter build web --release --no-pub --no-web-resources-cdn`，沿用本地API配置，核对完整字体不变。
- [x] 新建验证记录并更新HANDOFF及有关当前事实；保留进入本轮前工作区中的文档改动，不推送或部署。对未接供应商、终止、持久播放、固化和真实设备明确保留边界。
