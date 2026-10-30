# 设置页资格修补实施计划

> 按executing-plans/TDD内联执行；已有连续开发授权覆盖本次原规则修补，保留工作区，不提交/推送/部署。

**Goal:** 设置旧回调不能保存旧草稿到新身份、注销新账号或离开新页面。

**Architecture:** PreferencesScreen冻结展示来源，点击/确认时重查账号、API/controller/repository、偏好/草稿和当前路由；复用既有HTTP及路由协议。

**Tech Stack:** Flutter/Riverpod/go_router、WidgetTester、MockClient；无依赖变化。[设计](../specs/2026-10-25-preferences-action-guards-design.md)。

## 1 复现

- [x] 新增`apps/client/test/features/account/preferences_action_guards_test.dart`，用可注入状态且保留真实save/logout的AccountController、真实SimonTalkApp路由、捕获HTTP。旧FilledButton.onPressed后切owner、调用并断言PATCH为0；退出对话框打开后切owner再确认并断言POST logout为0。
- [x] 在`apps/client`执行`flutter test --no-pub test/features/account/preferences_action_guards_test.dart`，观察请求/导航业务断言失败；记录根因和边界。

## 2 修补

- [x] 修改`apps/client/lib/features/account/preferences_screen.dart`，在build捕获`session/draft/controller/repository/path`。`canAct`核当前phase/busy/user/API、同provider及`identical`偏好/草稿，`ModalRoute.isCurrent`和router最新URI；确认框使用本dialog的current并保留原页URI门。
- [x] 保存显式传draft；本地编辑、放弃、返回、退出都用快照门。异步保存只在相同账号/页且非busy时提示。确认框回调只可关闭自己，失效确认返回false。
- [x] 增补owner/API/busy/go/push/新草稿/偏好版本及合法路径、取消、迟到完成回归，再跑账号及练习/历史/恢复相关目标。

## 3 验证与交接

- [x] 运行全Flutter、分析、格式；Node传输测试、Web release及完整字体映射校验。生产只改设置交互，不改布局无需新预览；必要时浏览器补验。
- [x] 独立只读审查本次限定diff，确定问题先RED复现再修复；更新验证/HANDOFF/交互规格和验收矩阵，核原文件摘要与临时资源清理。


执行结果：页面89+异步22项新增；账号142、Flutter1347/10专用skip、Node58、分析/218格式、Web34.5秒和字体检查通过；独立静态复核发现问题已先RED再修补。见[验证报告](../../development/2026-10-25-account-action-scope-verification.md)。未提交/推送/部署。
