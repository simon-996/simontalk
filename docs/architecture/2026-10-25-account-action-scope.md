# 设置动作与异步账号范围

日期：2026-10-25。沿用[账号接口](2026-10-15-account-api.md)和[交互规格](../design/2026-10-15-screen-and-interaction-spec.md)，无新增后端接口、产品选项、依赖或媒体能力。

## 展示与点击

PreferencesScreen在每次build冻结账号、已存偏好对象、草稿对象、controller/repository和/account或/setup地址。所有保存、返回、退出、本地编辑与放弃点击重新检查signedIn、非busy、当前账号/API身份、同provider和原偏好/草稿；原ModalRoute须current，最新GoRouter URI也须匹配。按钮禁用之外仍检查回调，覆盖状态已变化但尚未重建的窗口。

保存显式提交当时展示的draft，不读取后来草稿。成功提示只在同身份、controller/repository、非busy及原当前页显示，不以原偏好对象阻止正常保存后的提示。初设保存仍走既有router重定向。

退出/放弃确认绑定原展示快照；确认期间继续核对账号、API、busy、偏好和草稿。确认框只能在自身ModalRoute仍current时关闭自身；确认后原页再次检查资格，再发退出或返回。旧确认/取消不能pop后来叠加的对话框或其他页。相应界面、文案和正常取消/保留行为沿用。

## HTTP与完成

AccountRepository对preferences GET/PATCH和logout显式传入调用时expectedAccountId，复用ApiClient既有CSRF、token读取及正常回包后的范围检查，不自动重放。跨标签Cookie变化继续由服务端X-Account-ID拒绝，不能把本机身份门当Cookie不可变化。

移动端退出的网络错误仍可在同身份下清本机并报告远端未确认；清理前再次核身份，避免旧网络异常删新凭据。tokenStore.delete完成后也核身份再清API owner。已开始的底层原生删除不可撤回，本轮没有真实安全存储并发I/O证据；这不是对原生原子切换的承诺。

AccountController的save/logout及restore各持唯一pending AccountState。每个异步完成、异常及冲突补读只在ref.mounted且state仍是该pending时发布，旧完成返回false或被忽略。自动401/account_changed恢复也复用独立_restore；恢复提示在同一个门内发布，不在恢复完成后无条件追加旧提示。

restore向repository传stillCurrent，读取token、权威me回复后写共享API身份之前、偏好返回及401清理前后检查操作和身份。旧恢复不能先改共享API owner再干扰最新恢复；null/A初态及两种回包顺序有行为覆盖。仓库直接调用不传stillCurrent时仍核本机身份，但不提供多操作generation仲裁；生产恢复路径由controller提供该门。

登录/注册/重设的完整并发状态机未在本轮重构。HTTP已发出或服务端已受理的操作不会因丢弃本机旧完成而撤销；本轮没有停止供应商、额度或原生媒体语义变化。

验证与范围见[实测报告](../development/2026-10-25-account-action-scope-verification.md)。
