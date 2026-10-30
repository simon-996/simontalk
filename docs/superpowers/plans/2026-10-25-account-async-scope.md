# 账号偏好/退出异步身份范围修补

> 连续执行已授权的账号隔离缺陷修补，使用systematic-debugging/TDD，不改产品选项，不提交/推送/部署。

**Goal:** 设置点击检查后，在CSRF或HTTP等待中切换账号，旧请求不能改新身份，迟到完成不能恢复旧账号。

**Architecture:** AccountRepository复用已有ApiClient.accountId显式冻结每次preferences GET/PATCH与logout的目标账号。AccountController.save/logout捕获唯一pending AccountState，在成功/失败/冲突补读回写前核同operation及ref.mounted。先修这两种已登录操作，复核后将其自动恢复及双恢复发布资格纳入；不重构登录/注册/重设。

**Tech Stack:** 既有Dart/Riverpod/HTTP MockClient及真实controller。相关文件`apps/client/lib/features/account/account_repository.dart`、`account_controller.dart`；新增测试`apps/client/test/features/account/account_async_scope_test.dart`。

- [x] 延迟Web CSRF后切API owner，save/logout断言无写且account_changed；延迟preferences GET回包后切owner，不返回旧身份数据。先RED复现。
- [x] 延迟save/logout成功或失败，期间替换controller状态为B，断言旧完成false、不覆盖B；save冲突补读期间切B同样保留B，controller销毁后不发布。先RED复现。
- [x] Repository的loadPreferences/savePreferences/logout传`accountId: api.expectedAccountId`，沿用既有CSRF/身份检查/异常规则，不自动重试；无身份的既有测试保持。
- [x] save/logout捕获repository及唯一pending，`isCurrent => ref.mounted && identical(state, pending)`，每次await后成功/异常/冲突补读前后检查；旧完成直接false。原account_changed/401恢复路径只在操作仍当前时继续，不改变已受理供应商或HTTP事实。
- [x] 运行两个账号新目标及现有账号/练习相关测试，独立审查；最终Flutter全量/分析/格式/Node/Web/字体，更新交接、接口交互约束及证据。无后端/DB/模型/原生/依赖变更。


执行结果：页面89+异步22项新增；账号142、Flutter1347/10专用skip、Node58、分析/218格式、Web34.5秒和字体检查通过；独立静态复核发现问题已先RED再修补。见[验证报告](../../development/2026-10-25-account-action-scope-verification.md)。未提交/推送/部署。

复核追加：restore拥有独立pending并把stillCurrent传入repository，权威me结果修改共享API身份前也查同操作；异常退出清理前后核身份。6项异常恢复/清理及两项双恢复已先RED，补足原计划直接回写以外的边界。原生已开始的delete不能撤回，真机I/O并发未验。
