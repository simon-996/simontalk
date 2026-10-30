# 历史导航守卫实施计划

> 依照executing-plans在当前已有本地功能分支逐项执行，保留原有改动；持续开发授权不重复确认，不提交/推送/部署。

**目标：** 旧历史按钮仅能打开当前账号、当前可用metadata允许的目标，不拼无效路径。

**结构：** 修改`apps/client/lib/features/history/history_screen.dart`的回调与账号busy，`apps/client/lib/features/history/history_view.dart`按读取state显示提示；回归放现有`apps/client/test/features/history/history_screen_test.dart`，复用真实路由、provider与HTTP fixture。[设计](../specs/2026-10-23-history-action-guards-design.md)。

- [x] 保存612个根目录原文件摘要；执行原历史/重练测试基线。命令均带`flutter test --no-pub`，不解析依赖。
- [x] 参数化旧详情回调测试：捕获HistoryView的onText/onReview/onSource/onTarget/onDelete/onRelated；改变`api.expectedAccountId`或通过真实controller.refresh进入未完成读取，再执行旧回调，断言URL仍为原详情且无额外HTTP。另验账号busy、sealed变unsealed；列表旧ID在owner变化/读中/下一页后不导航。先运行观察真实路由变化RED。
- [x] 最小修复：Screen内`canNavigate`点击时`ref.read(accountControllerProvider)`，检查signedIn/!busy/owner相同/c非busy；`currentItem`再读c.item并与URL小写ID一致。列表查c.page成员；文字/复盘检查isSealed，来源/目标检查rehearsal，关联ordinary，删除只需当前item。通过后再运行历史/重练目标回归。
- [x] 独立只读审查；全量Flutter/分析/206 Dart格式、Node58及Web发布/字体，核对依赖和后端不变。实际接口不变，本轮不创建夹具库或调用API；不将前批wire709等证据当本轮结果。
- [x] 更新验证与HANDOFF及历史契约的点击时规则；检查本地链接/围栏/git diff空白、原文件保留和临时文件清理。浏览器若仍禁用，标实际待补。

实际结果见[报告](../../development/2026-10-23-history-action-guards-verification.md)：新增27项而非初始26项，额外一项覆盖账号操作可见禁用/恢复与正确读取提示；实际浏览器仍待补。
