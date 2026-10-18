# Conversation Projection Implementation Plan

> 使用superpowers:executing-plans逐项实施，先失败测试再实现，完成后requesting-code-review独立只读审查。按持续授权在现有功能分支推进，不逐项确认；供应商、硬件和原生任务暂缓。

**Goal:** 将有界、可修订且不混淆生成/播放证据的对话快照接入现有媒体生命周期。

**Architecture:** features/conversation的不可变模型和纯内存投影；现有协议端口增加归一化回调，媒体控制器创建/守护/封存/清空原连接投影。没有新HTTP、存储或UI。

**Tech Stack:** Dart、Flutter ChangeNotifier、现有媒体/账号作用域，零新依赖。

## Task 1: 有界投影

- [x] 创建`apps/client/test/features/conversation/conversation_projection_test.dart`，先以`ConversationProjection(scope)`和`TranscriptUpdate`测试临时不进入context/final进入、final修订；运行`flutter test test/features/conversation`观察缺少实现的失败。
- [x] 新建`lib/features/conversation/conversation_models.dart`定义不可变scope、sealed update、角色/播放来源/状态、turn/snapshot/context；新建`conversation_projection.dart`实现`apply`返回applied/duplicate/stale/awaitingTranscript，`snapshot`、`seal`与`clear`。
- [x] 补测试：metadata/index冲突、空final、重发替换、UTF-8容量/原子拒绝、四类播放/版本错配/前缀位置回退、生成完成无播放、未来证据、文字修订重置、不可变列表和seal/clear。按设计实现严格验证，不保留原话事件历史。

## Task 2: 媒体消费

- [x] 新建`apps/client/test/features/realtime/practice_media_conversation_test.dart`，用现有MediaHarness先验证callbacks.emitConversation与controller.conversation缺失失败。
- [x] `realtime_session_protocol.dart`增加必需的`emitConversation`回调（现有唯一创建者为媒体控制器，不静默丢弃事实）；`practice_media_controller.dart`在连接创建后建scope/投影，回调经过guard/已确认同一通道，再apply并通知；固定conversation_invalid/conversation_limit_reached错误不带正文。
- [x] stop正常seal、账号变化/销毁clear；conversation getter账号变化时不泄露原快照，迟到不能重建。验证默认拒绝不建投影、配置前/其他通道拒绝、激活等待可接收、原始播放观测不造文本、stop/身份/销毁与容量失败释放。

## Task 3: 完成与证据

- [x] 串行运行全量Flutter、分析/格式、Node、Web release及字体；独立只读审查模型/投影/媒体接入，修复确定问题并复验。
- [x] 新增架构契约和验证记录，更新技术设计/媒体契约/本地开发/HANDOFF与计划完成项；核对文档链接/git diff，本地提交，不推送。

## 实际收尾

基线232项；新增模型/回调先失败，再实现。37+9项定向通过，补4项边界后全量282、Node51、分析/75文件格式、Web release34.5秒和字体通过。独立只读审查未发现确定问题。后端未改，不重跑/冒充新后端证据。结果与边界见[验证记录](../../development/2026-10-18-conversation-projection-verification.md)。
