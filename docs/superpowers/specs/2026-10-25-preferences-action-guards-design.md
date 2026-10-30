# 设置页点击与确认资格修补

依据已有账号隔离、偏好版本冲突、原页确认及连续开发授权，修复PreferencesScreen旧回调影响新账号/页面的缺口，不新增产品选项或视觉方案。遵循systematic-debugging、TDD及UI/UX Pro Max确认/成功反馈原则；本项目Flutter及既有交互规格优先。

## 根因与方案

当前按钮大多只使用build时busy；保存读可变_draft并由当前controller确定账号，退出确认只检查mounted，返回确认也未复验来源。假设：账号/路由/草稿变化后，旧保存/退出/放弃仍可生效。先用真实controller+HTTP替身及真实router复现。

采用与练习页一致的点击时门控：冻结展示账号、偏好对象、草稿对象、controller及repository；点击须signedIn/非busy、API身份仍属于此账号、provider身份不变、草稿/已存偏好仍是展示版本。页面必须为当前ModalRoute且最新URI为/account或/setup。只在build禁用或只在controller加busy不能识别展示来源，不采用；全局重构账号状态机超出本次根因，不采用。

所有本地编辑/放弃、保存、返回及退出均走同一资格检查。保存使用本次明确展示的draft，不读取未来草稿；成功反馈另核同账号/controller/repository/路由及非busy，不用已经更新的偏好对象阻止正常成功提示。确认框绑定原展示快照；确认期间再查账号/busy/草稿/偏好与最新URI，并核本确认框的ModalRoute仍current。旧确认不关闭其他页面/确认框、不注销新账号或丢弃新草稿；正常保留/取消可关闭自身对话框。

原偏好PATCH/CSRF/版本冲突与AccountController协议保持；初始设置正常保存后仍由已有router进入练习，不添加自动请求、模型或媒体。原登录恢复/退出失败行为保留。

## 验证

保存/退出旧回调在owner/API身份/busy/新偏好/新草稿及go/push切页后无写无导航；本地旧编辑不覆盖新草稿；退出/放弃确认在owner/偏好/草稿/busy/路由变化后不跨来源。合法保存/确认/取消/返回仍工作；迟到保存不在其他页面显示成功提示。先观察业务断言失败，再修复并跑账号/练习目标、Flutter全量、分析/格式、Node与Web字体检查。保留工作区所有原文件，本轮不涉及后端/DB/模型/原生/提交/推送/部署。


## 连续异步单元

点击门之后仍需固定HTTP目标与完成来源。新增[账号范围契约](../../architecture/2026-10-25-account-action-scope.md)：preferences/退出使用显式accountId，save/logout/restore持唯一pending且销毁后不发布；restore向仓库传stillCurrent，防旧操作先改共享身份；退出清理前后核身份。保持Cookie/原生存储已有平台差异，已开始的原生delete无法撤回，不作原子身份切换承诺。
