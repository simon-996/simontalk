# Web Realtime Transport Implementation Plan

> 使用 executing-plans 在当前干净的功能分支内逐项执行。用户要求持续推进，设计与执行方式无需再次确认；不切换主分支，不推送。

**Goal:** 实现真实WebRTC传输与Flutter桥接，保留配置确认、停止和上游终止的边界。

**Architecture:** 浏览器脚本持有媒体，Dart定义信令及观察接口；模型协议之后接入。现有真实准入503保持有效。

**Tech Stack:** Flutter/Dart JS interop、浏览器WebRTC、Node内置测试。

执行结果：2026-10-17完成下列工程与验证。本机物理许可和供应商条件按最新指令暂缓，未把它们计作验收通过。证据见[验证记录](../../development/2026-10-17-web-realtime-transport-verification.md)。

## Task 1: 传输与资源协议

- [x] 新建`apps/client/test/web/realtime_transport_test.mjs`，覆盖创建无副作用、Offer只走一次、真实轨道配置前不挂载、连接和通道不同顺序、服务端通道、取消后晚到与幂等关闭。
- [x] `node --test test/web/realtime_transport_test.mjs`观察缺少生产脚本失败。
- [x] 新建`apps/client/web/realtime_transport.js`，接口为`create().start(exchangeOffer,onObservation,onEvent,onCancel)`、`activate(channelId)`、`send(json,channelId)`、`setMuted(bool)`、`resumePlayback()`、`stop()`；失败只返回稳定code。
- [x] 补超时、后台、失效、播放限制、缓冲与输入边界测试，逐项红绿验证。

## Task 2: Flutter桥接与加载

- [x] 在`apps/client/lib/features/realtime/`添加`RealtimeTransport`、`RealtimeSignaller`、平台工厂和Web桥接；原生返回unsupported。
- [x] 桥接只传有界字符串与通道ID；信令取消由实例持有，不复用其他业务请求。
- [x] `web/index.html`异步加载可选脚本，失败通知不阻塞账号页面；扩展`test/web/startup_test.mjs`先观察失败再实现。
- [x] `dart format`、`flutter analyze`、`flutter test`、全部Node测试和Web release构建通过。

## Task 3: 实际验证与交接

- [x] 在可访问的本地浏览器验证正式应用启动和可选脚本加载；本机媒体条件具备时做真实检查，缺少条件如实记录。
- [x] 更新技术设计、本地开发、验证记录及HANDOFF，分别列替身、真实浏览器与未验证能力。
- [x] `git diff --check`与复核通过后本地提交；保留分支，不推送、不部署。
