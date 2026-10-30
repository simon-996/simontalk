# 当前账号与偏好真实浏览器补验

日期：2026-10-25（Asia/Shanghai）。承接[设置与异步范围](2026-10-25-account-action-scope-verification.md)、[认证范围](2026-10-25-auth-operation-scope-verification.md)两批工程验证，按[计划](../superpowers/plans/2026-10-25-browser-account-acceptance.md)补实际页面证据。使用现有最新Web release，产物晚于全部lib源码，未改应用源码或重新构建；前批Flutter1401/10skip、Node58及Web33.3秒是历史结果，本轮不重标。

## 环境与结果

桌面IAB → loopback7357代理 → 默认供应商关闭的API8001 → 专属`simontalk_auth_browser_20261025_c94e2_test`。两合成账号由既有实际注册接口建立，A初始未选难度，B预设beginner；实际浏览器只登录既有测试身份，不提交注册或密码重设，不用物理麦克风。代理私有文件控制一次拒绝或延迟，不开放控制端点。42条请求元数据中，3条503由代理在上游前模拟拒绝，其余39条转真实API；另有fixture ASGI调用及一次同A移动身份的实际GET/PATCH，不混作浏览器操作。

| 场景 | 实际结果 |
| --- | --- |
| 登录与初设 | A浏览器登录200 → /setup，选择自然交流并PATCH200 → 练习首页显示已选难度 |
| 本地修改/正常保存 | 深入表达草稿可明确放弃，恢复原自然交流；修改慢速并保存200，真实出现成功反馈，刷新后自然交流/slow仍在 |
| 取消/成功退出 | 退出先确认，取消保留A；另一标签明确确认后204 → 登录页，再登录B200；后续B明确退出204、A重新登录200 |
| 偏好保存失败 | 一次代理503后显示失败，原advanced草稿与明确保存按钮保留，服务端仍v3/intermediate |
| 同账号版本冲突 | 同A独立移动凭证实际将v3改为v4/beginner；浏览器旧v3草稿PATCH409，随后GET实际v4，清旧草稿并显示版本冲突，不覆盖服务端 |
| A旧退出遇B Cookie | A退出确认保留时，第二标签完成A退出并登录B；旧确认实际403，不自动重放。本人再次明确确认，重新CSRF后实际409/account_changed，恢复B并显示身份变化，B会话仍可读取 |
| 退出服务失败 | B一次代理503后仍显示B和退出未确认；另一标签实际刷新及偏好读取仍为B。随后明确确认可正常退出 |
| B旧草稿遇A Cookie | 保留B的advanced草稿，再由另一标签明确退出B并登录A；旧B保存先获取当前CSRF，PATCH409后GET恢复A。没有把旧草稿写A/B；B最终仍v2/beginner/normal |
| 保存回包迟到与返回 | 首轮5.015秒响应实际是过期CSRF403，不能算成功。明确重做后成功200延迟5.019秒；等待中浏览器后退到首页，迟到后仍/practice，显示实际新advanced偏好，旧保存成功提示计数0 |
| 偏好恢复503 | 刷新时me200而偏好代理503，显示暂时连接不上/明确重新连接；Cookie保留，点击重连恢复A及实际advanced偏好 |
| 恢复读取迟到 | /account刷新读取偏好200被延迟5.023秒，等待中浏览器后退到/practice；返回后仍为当前练习地址，没有被旧设置地址覆盖 |

时长是本机代理观测值，不是延迟分位数或设备网络承诺。注册/密码重设浏览器提交、精确浏览器版本、实际手机/大陆网络和全部旧回调竞态仍未覆盖。

## 过程限制与截图

Flutter可访问性入口首次click未启用，Space后成功；个别首语义帧无文字，等实际控件可见后操作。首次fill因autofill替换焦点失败，改为原生点击/输入后成功。离视口的radio DOM点击未改值，实际滚回后点击成功；未据此改应用代码。首次迟到保存预期成功但实际403已在上表区分，没有把等待目标未出现当生产缺陷。

九张截图逐张查看：[保存后界面](screenshots/browser-account-saved.png)、[保存失败保留草稿](screenshots/browser-account-save-failed.png)、[版本冲突](screenshots/browser-account-version-conflict.png)、[旧CSRF退出拒绝](screenshots/browser-account-stale-csrf.png)、[恢复B身份](screenshots/browser-account-cross-owner.png)、[退出失败](screenshots/browser-account-logout-failed.png)、[旧B保存拒绝并恢复A](screenshots/browser-account-old-save-rejected.png)、[迟到成功后首页](screenshots/browser-account-late-save-home.png)、[恢复读取失败](screenshots/browser-account-restore-failed.png)。截图为桌面1280×720视口的局部滚动区域，不替代其他设备验收。

## 数据与清理

[脱敏请求/数据库摘要](evidence/2026-10-25-browser-account-acceptance.json)只含方法、路径、状态、耗时、控制场景及摘要，无Cookie、密码、token或请求正文。最终A v5/advanced/slow、B v2/beginner/normal，2用户/5登录会话，其中2次正常退出已撤销；没有练习、连接、复盘任务/尝试/结果或密码重设凭证。开发20业务表和迁移记录共21表全行摘要一致。

两个测试标签、API/Web服务及独立库已清理；删除库前零活跃连接，8000/8001/7357端口均关闭。开工732个既有文件均保留；只更新HANDOFF/本地运行/验证三份原文档，其余原文件摘要一致。12个本轮私有文件已移除，5份文档270个本地引用及Git空白检查通过。本轮无应用/schema/依赖修改、模型调用、原生构建、提交/推送/部署；没有将本机字段和会话保护当成上游终止或完整B2/B5/B6。
