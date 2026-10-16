# Web 字体加载实施计划

> **For agentic workers:** Use superpowers:executing-plans，按当前用户持续推进指令在本会话执行；已有功能分支内工作。

**Goal:** 减少首帧中文字体负载，保留完整源字体覆盖和明确失败恢复。

**Architecture:** 完整WOFF2为Web专用asset；条件导出隔离原生，main等待字体注册后运行业务应用。失败通过现有HTML启动事件呈现。

**Tech Stack:** Flutter FontLoader、Dart JS interop、fontTools/Brotli、现有Node启动测试。

## 1. 字体产物与校验

- [x] 创建`scripts/check_web_fonts.py`：对原TTF和目标WOFF2做Unicode映射、字形度量/轮廓、fvar/gvar及布局/许可证元数据比较，拒绝大于8MiB的中文字体。先运行，确认目标缺失失败。
- [x] 创建`scripts/prepare_web_fonts.py`完整转换源文件，不裁字或改名；固定fontTools/Brotli版本。运行生成，再运行校验通过。
- [x] 修改`apps/client/pubspec.yaml`，移除NotoSansSC共同fonts声明，增加`path: assets/fonts/NotoSansSC.woff2`与`platforms: [web]`；Roboto保持本地引擎回退。

## 2. Web加载与恢复

- [x] 添加`lib/core/app_fonts.dart`条件导出、`app_fonts_native.dart`空实现、`app_fonts_web.dart`以FontLoader注册字体与JS启动失败事件。
- [x] `main()`初始化binding并await字体；成功runApp，失败报告现有启动错误事件。业务运行不增加假页面。
- [x] Flutter分析/28项回归、Node启动10项回归；Web release构建，核对发布manifest、文件和体积。

## 3. 浏览器与交接

- [x] 正式产物实际中文登录与设置可读；临时WOFF2故障源404触发可读重试，停止临时服务并关闭自己的测试页。
- [x] CI加入字体校验；更新字体README、开发说明、HANDOFF与本轮验证记录；独立复核重要改动并修复问题。
- [x] 最终验证后本地提交；继续路线下一项可执行工作，不推送、部署或调用未授权付费服务。

完成证据见`docs/development/2026-10-16-web-font-verification.md`。追加生成长度/摘要元数据与运行时验证，独立复核发现的字体解析P2已修复并经404、200错误内容、等长损坏验证。
