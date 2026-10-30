# 登录、注册与重设范围验证

日期：2026-10-25（Asia/Shanghai）。按连续开发授权完成“认证服务层→认证页面”两组修补，见[计划](../superpowers/plans/2026-10-25-auth-operation-scope.md)及[契约](../architecture/2026-10-25-auth-operation-scope.md)。

## 复现与修补

- 第一组15项全部先RED：login/register/reset在CSRF等待、成功/失败回包或销毁后可影响新状态；clearError可解除busy。现控制器使用唯一pending/ref.mounted/provider门，仓库操作scope复验身份及凭据发布，ApiClient在原await边界检查有效性。
- 第二组页面26项先18失败、8通过：旧submit/nav可越过切页，reset迟到成功可抢路由。现捕获展示state/账号API身份/provider，点击与键盘提交复验当前Route和URI；迟到提示只属于原当前页。
- 独立静态审查发现空身份冻结遗漏：只改变API owner而不替换pending时，accountId:null不能阻止旧POST。补login/register/reset×CSRF/token等待共6项，全部先RED，再将包含null的冻结owner并入请求stillCurrent。当前操作身份失效转unreachable，要求明确恢复。
- 另补偏好补读晚到2项、非法移动token2项及正常三页提交3项。新增共54项（25服务层+29页面）；不宣称所有后补用例都逐项RED。

原账号142项保留，最终目标196项通过（约8秒）。使用真实AccountController、AccountRepository、ApiClient、SimonTalkApp/go_router；HTTP为MockClient。无本轮真实API、数据库、浏览器Cookie、模型或原生I/O调用。独立复审未发现剩余确定问题，审查者未运行Flutter。

## 最终检查

| 检查 | 结果 |
| --- | --- |
| Flutter全量 | 1401通过/10专用夹具skip，43秒 |
| 分析/格式 | 无问题，220个Dart文件无格式变化 |
| Node传输 | 58通过 |
| Web release | release通过，33.3秒 |
| 字体 | 完整30,890 Unicode映射及发布字体验证通过 |

生产仅改ApiClient、AccountRepository、AccountController、AuthScreen；没有布局/文案/预览注册变化，本轮没有把旧截图或Preview标为实际浏览器复验。已发HTTP/Cookie响应及已开始原生存储I/O不可撤回；真实设备及跨标签原子身份切换不由本单元证明。后端、schema、依赖及锁文件未改，未调用模型/麦克风，未构建原生，未提交/推送/部署。

## 保留与清理

开工全部726个既有跟踪/未跟踪文件保留，无丢失；仅四份生产文件及HANDOFF/账号契约/交互/验证/本地运行五份文档有意更新，其余原文件摘要一致。[脱敏执行摘要](evidence/2026-10-25-auth-operation-scope.json)记录测试、范围和源码摘要，不含密码、Cookie或用户正文。8份文档312个本地引用、围栏及Git空白检查通过；12个本轮私有日志/快照已清理，没有创建服务或测试库。
