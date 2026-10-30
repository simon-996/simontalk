# Review Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development, then independent specification and quality review. Steps use checkbox (`- [x]`) syntax.

**Goal:** 从真实封存来源进入可刷新、可明确操作的复盘阅读页。

**Architecture:** 原账号来源协调器组合现有PracticeReviewClient，route仅传session UUID，GET来源→GET复盘，视图/预览独立；保留pending和身份门。

**Tech Stack:** Flutter/Dart、Riverpod、go_router、既有ApiClient，主题/字体不变。

---

依据[完整设计](../specs/2026-10-21-review-page-design.md)实施。保留当前分支全部dirty，应用代码由单实施agent独占；root负责文档/隔离fixture/释放后的独立运行和浏览器/预览。无真实供应商、原生、提交/推送/部署或依赖升级。

### Task 1: 来源、路由、真实界面与回归

**Files:** 新`apps/client/lib/features/review/review_page_controller.dart`、`review_screen.dart`、`review_page_view.dart`、`review_page_previews.dart`（需要时小型preview fixture文件）；修改`review_providers.dart`、`app.dart`及`practice_recovery_panel.dart`以接入口；新`test/features/review/`对应源/页/入口/route/预览回归。原client、backend、媒体和锁文件保持，不因UI绕过客户端门。

- [x] 先行为RED：sealed恢复摘要旁有复盘入口，ending/身份错误时无入口；实际缺少入口失败后再实现。

```dart
testWidgets('only a verified sealed source opens review', (tester) async {
  await tester.pumpWidget(recoveryWithSealedSummary());
  expect(find.text('查看复盘'), findsOneWidget);
});
```

- [x] 实现本人GET completion的严格身份/原scope解析、ending/缺失与sealed target；来源阶段8秒、任务阶段沿原client8秒，单飞/取消/迟到/账号保护，源读清显示而相同target保留pending，不在构造时请求。
- [x] 页面与route接入，仅session UUID；初次进入主动纯读、刷新地址保留review路径、恢复/不可达账号不请求、无效ID零HTTP。应用内push/返回、已读sealed入口当前值复核，禁止新媒体和自动生成。
- [x] 纯视图展示真实九态/读取与不确定写，按钮只映射允许动作；服务器实有0–3items及类型/精确原话/解释，没有假统计/重练/跳转按钮。源/任务失败及身份变化清旧可见内容。
- [x] 使用项目主题、LayoutBuilder max680/SafeArea/单滚动、长文本选择、48高按钮、焦点/heading/liveRegion/减少动画；按Flutter响应式、widget-preview与UI/UX skill写隔离浅色三项/深色320 200%及blocked等预览。样例不进入真实页面fallback。
- [x] 补源/页/route/入口及所有状态/动作/身份/失败/复制/多尺寸/主题/大字号/预览测试，目标、完整Flutter、analyze/format通过后释放Flutter工具。明确RED日志与变更文件，等两阶段复核修复。

### Task 2: 独立复核

- [x] 规格审查来源、只读/明确动作、生命周期/身份、导航、状态/范围及实有文案；修补RED并复审通过。
- [x] 再质量审查异步/取消/清理/路由及组件约束和测试；修复后通过。

### Task 3: 主任务实测与交接

- [x] 独立完整Flutter/Chrome/analyze/格式、Node/Web/完整字体；不将前批API506重标为重跑。
- [x] 独立API/数据库/账号与真实浏览器验入口、blocked0次→有效三项、读取断网/明确恢复、B空态/跨标签隔离、窄屏/键盘；实际看浅深/大字号预览。所有fixture与真实产品证据区分，清理临时身份/文件/服务/标签。
- [x] 开发库17表/revision未污染、默认API健康/锁文件/空白，更新HANDOFF及对应规格/架构/报告与链接；明确未实现的完整历史/话轮跳转/重练/真实模型。

验收于2026-10-22完成，实际结果、最终重复浏览器身份检查的工具超时限制及清理见[完整报告](../../development/2026-10-21-review-page-verification.md)。浏览器/复审暴露的URL/编码历史/无难度账号、异步焦点与连接创建跨时钟均先RED后修；后端额外独立库507通过并已删除，未放宽客户端或改变迁移/依赖。
