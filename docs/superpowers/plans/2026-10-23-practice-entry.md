# 普通练习入口 Implementation Plan

> **For agentic workers:** 使用 superpowers:executing-plans；按下列复选框逐项执行，不提交、推送或部署。

**Goal:** 落实基础版本B1，把真实账号、难度、准备/恢复接入首页与准备页。

**Architecture:** 新入口协调器组合原恢复和准备控制器；纯视图与账号/路由绑定分开。复用主题、恢复面板和安全清理，后端与媒体网关保持原状。

**Tech Stack:** Flutter Web、Riverpod、go_router、现有HTTP API及锁定依赖。

规格见[入口设计](../specs/2026-10-23-practice-entry-design.md)。用户“继续”授权在当前已有功能分支实施；保留之前全部未提交改动。

## 执行清单

- [x] 1. 在`apps/client/test/features/practice/practice_entry_controller_test.dart`写入口行为失败测试：初始无请求，current前置读取、占用拒绝、503、单飞、原key确认、取消/后台/身份/销毁迟到结果；运行并记录RED。
- [x] 2. 新建`apps/client/lib/features/practice/practice_entry_controller.dart`及`practice_entry_provider.dart`，只组合既有控制器；目标测试GREEN。
- [x] 3. 在`apps/client/test/features/practice/practice_entry_screen_test.dart`写首页/准备/设置/直接路由/错误与尺寸测试并记录RED；账号原测试明确设置入口，首次设置后预期首页。
- [x] 4. 新建`practice_entry_view.dart`与`practice_entry_screen.dart`；修改`apps/client/lib/app.dart`的已登录路由，修改`features/account/preferences_screen.dart`增加明确返回，修改`practice_recovery_panel.dart`允许复用入口控制器。目标测试GREEN，保留既有深链接回归。
- [x] 5. 新建`practice_entry_previews.dart`及对应视图/预览检查；浅深/窄宽/200%字号/横屏/键盘；尝试实际浏览器/Preview，禁用时保留缺项并实际查看组件渲染。
- [x] 6. 在独立测试条件下验证实际默认503及零新增练习；记录HTTP来源和清理结果，凭证不输出/提交。
- [x] 7. 运行客户端全量测试、分析/格式、Node桥接、Web构建和字体核验，检查锁文件及原改动保留。
- [x] 8. 按实际证据更新`HANDOFF.md`、基础路线B1、交互/本地开发与验证记录；明确仍缺真实语音及实际浏览器项目。检查本次文件差异和文档引用。

## 检查命令

在`apps/client`，使用本机Flutter/Dart工具链：

```sh
flutter test --no-pub test/features/practice/practice_entry_controller_test.dart test/features/practice/practice_entry_screen_test.dart
flutter test --no-pub
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
node --test test/web/*_test.mjs
flutter build web --release --no-pub --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

目标测试首次必须因缺少入口行为而失败，实施后全部通过；缺夹具skip不充当验证成功。仓库根目录用`uv run scripts/check_web_fonts.py --web-build apps/client/build/web`核验字体；后端未改不重跑API全量。文档和空白检查独立完成。

执行结果见[2026-10-23验证报告](../../development/2026-10-23-practice-entry-verification.md)。本单元完成不代表真实语音接入。
