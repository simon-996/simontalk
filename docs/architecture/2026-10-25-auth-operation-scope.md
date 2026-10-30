# 登录、注册与密码重设的操作范围

日期：2026-10-25，接续[设置与账号异步范围](2026-10-25-account-action-scope.md)。本单元复用原账号接口、Cookie/CSRF与偏好协议，无新增服务端能力、依赖或页面样式。

## 控制器与仓库

authenticate/resetPassword各冻结唯一pending AccountState和repository；成功/失败仅在ref.mounted、同pending及同repository时发布。authenticate(action)签名保留，action收到repository.scopedTo(isCurrent)，共享原API且不拥有关闭资源，嵌套scope合并有效性。clearError在busy或无error时不改变状态，不能借清错误解除进行中的操作或允许重复提交。

仓库在登录/注册请求前冻结API owner，包含null；HTTP回包后、身份/token发布前、存储完成及偏好补读后均检查操作与身份。手机token先完整校验再发布API身份。当前操作发现身份变化进入unreachable，保留明确恢复入口；已过时/销毁的操作只返回false，不覆盖新状态。合法认证已受理而偏好读取失败仍为session_pending，恢复现有会话，不重新消耗邀请码。

ApiClient.request增加默认null的stillCurrent同步纯判断，在原checkAccount的请求前、CSRF后、移动凭据读取后及正常回包后检查。登录/注册/reset传入冻结owner与操作的组合门，不能用accountId:null表示的“未要求身份绑定”代替“进入时确实无身份”。对其他调用默认行为不变，不增加自动重试。

## 页面

/login、/join、/reset捕获展示state、controller/repository、API owner及模式路径。按钮、键盘提交、页间导航和密码显隐重新检查signedOut、非busy、原展示state/provider、当前ModalRoute与最新URI。旧按钮在状态已变化但尚未重建时也不能提交或导航。

提交成功后清除自身敏感输入；reset的成功提示及返回登录另查当前页和身份，不能因旧reset成功抢后来页面。正常表单校验、明确提交、初设/练习跳转、重设成功提示沿用。

## 验证边界

外部HTTP为MockClient；真实controller、ApiClient和router参与测试。已发出的HTTP和Cookie响应不能撤回，已开始的原生安全存储I/O也不能撤回；本单元不提供服务端会话取消、跨标签Cookie原子化或真机存储并发证明。请求尚未发出时的过时操作抑制，以及本机身份/状态发布保护，分别以行为测试验证。结果见[验证报告](../development/2026-10-25-auth-operation-scope-verification.md)。
