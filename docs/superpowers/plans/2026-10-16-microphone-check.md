# Web 麦克风检查实施计划

> **For agentic workers:** 使用superpowers:executing-plans在现有功能分支执行；用户明确要求持续推进、不询问常规选择。

**Goal:** 在正式Web偏好页完成可取消、及时释放的本机输入音量检查。

**Architecture:** 本地JS媒体适配器负责浏览器资源，Dart控制器处理状态/计时，Flutter内嵌面板复用主题与账号隔离。没有音频上传和模型连接。

**Tech Stack:** MediaDevices、Web Audio、Dart JS interop、ChangeNotifier、Flutter现有组件、Node内置测试。

## 1. 实际媒体生命周期

- [x] 先写`apps/client/test/web/microphone_probe_test.mjs`，用延迟授权承诺与明确的轨道/上下文替身，验证不自动申请、拒绝、取消后晚到释放、后台、轨道结束、清理和不连接扬声器；运行确认失败。
- [x] 实现`apps/client/web/microphone_probe.js`，提供`supported/create`与单次`start/stop`；错误返回稳定代码，所有终止路径释放；由index加载本地脚本。运行上述测试通过。

## 2. 控制器与适配

- [x] 先写`test/features/audio_check/microphone_check_controller_test.dart`，验证等待取消、20秒等待限制、30秒采集上限、过时结果、拒绝和dispose；用tester时钟推进，先确认失败。
- [x] 实现`lib/features/audio_check/microphone_probe.dart`接口、条件factory及Web/native适配器；`microphone_check_controller.dart`维护状态、代次、timer与回调。对应测试通过。

## 3. 正式界面与验收

- [x] 实现纯展示view与状态面板，给窄屏深浅色/错误/等待状态加无权限的静态Preview注解；偏好页以账号ID作为key接入，仅Web非onboarding显示。
- [x] widget测试覆盖触发前无申请、取消/停止、200%字号下按钮可达与账号key切换销毁；分析/全量Flutter、Node、release构建通过。
- [x] 浏览器检查实际入口与非采集状态，不接受未授权麦克风许可；独立复核竞态和资源清理。更新规格、CI、验证记录与HANDOFF，本地提交后继续下一项可执行任务。

完成证据见`docs/development/2026-10-17-microphone-check-verification.md`。复核增加脚本准备/晚到就绪与AudioContext中断两项P2回归，均已修复。真实硬件/许可保持未验收；本地提交后持续推进下一项。
