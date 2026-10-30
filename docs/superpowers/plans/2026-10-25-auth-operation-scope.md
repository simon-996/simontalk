# 登录、注册与重设的操作范围

按连续开发授权执行原账号隔离规则，使用排错/TDD；不改产品流程、布局、接口或依赖，不提交/推送/部署。

**Goal:** 旧登录/注册/密码重设的CSRF等待、回包和偏好补读不改新身份或销毁后的状态。

**Architecture:** authenticate/resetPassword沿用已采用的唯一pending与ref.mounted门；clearError不释放busy。AccountRepository派生共享API、不拥有新资源的操作范围，身份/凭据发布前检查stillCurrent。ApiClient.request增加默认不启用的stillCurrent回调，在原checkAccount的每个await边界同步检查，避免尚未发出的旧POST继续执行。已发HTTP/原生存储I/O不能撤回，不冒充服务端取消。

文件：修改`apps/client/lib/features/account/account_controller.dart`、`account_repository.dart`、`apps/client/lib/core/api_client.dart`；新增`apps/client/test/features/account/auth_operation_scope_test.dart`。

- [x] 先RED：login/register/reset在CSRF等待中失效不POST；成功/失败晚到不覆盖新状态，销毁不发布；登录/注册旧回包不改API身份/token；clearError不允许第二次提交。
- [x] 控制器捕获repository/pending，action使用repository.scopedTo(isCurrent)，所有成功/异常回写先复验；不改原authenticate(action)签名。
- [x] 仓库操作范围合并门并冻结调用时owner；在请求前、回包身份/凭据发布前、存储/偏好补读后检查。请求通过stillCurrent跨CSRF/token/回包边界；无门的旧调用保持兼容。手机token先完整校验再改API身份。
- [x] 目标通过并补正常提交、明确session_pending、合法空凭据拒绝/未知存储限制；独立只读复核，确定问题先RED再修。
- [x] Flutter全量/分析/格式、Node/Web/字体，更新HANDOFF及验证/契约；原文件摘要保留、临时日志清理。外部API仅MockClient，无数据库/真实模型/原生构建。


## 连续页面单元

- [x] 新增`auth_screen_guards_test.dart`：三页提交/导航分别覆盖go/push/busy/owner，以及reset迟到成功go/push，共26项，先观察18失败再修补。
- [x] AuthScreen捕获展示state/controller/repository/API owner和模式路径；点击及键盘提交复查signedOut/非busy、原state/provider、Route current与最新URI；显示密码同门。reset成功提示另核当前页面，不覆盖新页面。
- [x] 保留原表单校验、初设跳转、明确密码重设提示；测试沿用真实router和controller，不新增布局/页面或供应商路径。


执行结果：新增54项（服务25/页面29），账号196、Flutter1401/10专用skip、分析/220格式、Node58、Web33.3秒及字体通过。独立审查null owner遗漏以6项RED复现修补，最终静态复审无剩余确定问题；原生已发I/O及已发HTTP/Cookie不可撤回。见[验证](../../development/2026-10-25-auth-operation-scope-verification.md)。
