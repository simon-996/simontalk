# 注册与密码重设真实浏览器补验

日期：2026-10-25，Asia/Shanghai。补足[前次账号浏览器报告](2026-10-25-browser-account-acceptance-verification.md)明确未覆盖的注册/重设提交，按[计划](../superpowers/plans/2026-10-25-browser-registration-reset.md)执行。应用源码、依赖、schema及Web产物均未修改，未重新构建或重跑无关测试；此前Flutter1401/10skip、Node58、API975等保留历史证据。

## 环境与结果

当前Web release → 桌面IAB真实Cookie/JS → loopback7357代理 → 默认模型/信令关闭的API8001 → 专属`simontalk_register_reset_20261025_e81f4_test`。Web产物晚于111份lib Dart源码，开始/结束SHA256一致。`127.0.0.1`保留已登录测试会话，`localhost`使用独立Cookie范围操作注册拒绝与重设；两来源均为原有本地允许来源，未放宽安全配置。全部账号和凭证为本轮生成的合成测试数据。

代理记录24条浏览器请求，仅存方法/路径/状态/耗时；23条转发真实API，1条503在上游前拒绝。签发邀请/重设使用既有维护函数；另有直接真实HTTP的旧移动登录/读取和另一旧重设凭证拒绝检查，与浏览器操作分别记录，详见[脱敏摘要](evidence/2026-10-25-browser-registration-reset.json)。

| 场景 | 实际结果 |
| --- | --- |
| 注册密码确认不一致 | 页面显示两次密码需一致，注册POST计数为0 |
| 无效邀请 | 真实POST400，显示邀请无效，保留表单 |
| 合法注册与初设 | 真实POST201 → /setup，账号为browser_reset_a；选择自然交流、PATCH200 → /practice，偏好v2/intermediate/normal |
| 邀请重复使用 | 另一Cookie范围以不同用户名提交原邀请，POST400；数据库始终1用户/1已消耗邀请，没有第二账号 |
| 无效重设凭证 | 真实POST400，显示reset_invalid对应提示，输入与明确更新入口保留；未演练自然过期 |
| 重设服务失败 | 代理503保留凭证和两次密码输入；数据库仍2活跃会话/2未消耗重设凭证，证明尚未调用真实重设 |
| 正常重设 | 明确重试POST204，回/login显示成功提示、登录字段为空；原Web及移动两个会话均撤销，两个旧重设凭证均消耗 |
| 原登录与旧密码 | 原Web标签刷新GET me401回登录；旧移动Bearer实际GET me401。修正输入后的完整用户名+旧密码POST401，新密码POST200并保留原难度 |
| 已用及其他旧凭证 | 浏览器再次提交原凭证POST400；另一旧凭证另经直接真实HTTP返回400/reset_invalid，未再次改密码 |
| 迟到重设 | 另一合法凭证的真实204回包被代理延迟5099.5ms；等待中浏览器后退/login，busy期间禁操作。回包后仍/login、busy解除，无旧成功提示；之前密码POST401、最新密码POST200，原先登录的另一标签刷新再次401 |

后退只限制旧页面发布结果，不能撤回已经在服务端执行的改密。时长只代表本机这一请求，不是网络性能承诺。

## 截图与过程限制

七张1280×720桌面视口截图均实际查看：[注册拒绝](screenshots/browser-register-invalid.jpg)、[注册进入初设](screenshots/browser-register-setup.jpg)、[无效重设](screenshots/browser-reset-invalid.jpg)、[重设成功提示](screenshots/browser-reset-success.jpg)、[旧密码被拒](screenshots/browser-reset-old-password-rejected.jpg)、[迟到后登录页](screenshots/browser-reset-late-login.jpg)、[最新密码登录首页](screenshots/browser-reset-new-password-home.jpg)。不保存有效邀请/重设凭证的截图，也不保留明文密码。

原生输入自动聚焦曾漏掉用户名开头字符，首轮旧密码401因此不计为改密验收（请求摘要第15条）；明确点选/全选重填后，用完整用户名重新验证401→新密码200，截图已替换为正确输入的复验结果。初次注册展示名和用户名也在合法注册前纠正。没有把自动化输入不稳定直接判为生产缺陷。刷新需重新启用Flutter可访问性，实际操作后再读取当前控件。

此次未发现需修改应用源码的确定问题。没有记录精确浏览器版本，未覆盖手机、辅助技术、真实大陆网络、全部竞态或凭证自然过期；不标记完整支持矩阵、B2/B5/B6完成。

## 数据与清理

最终1用户/1已消耗邀请/4登录会话，其中3撤销；3重设凭证全部消耗，偏好保持v2/intermediate/normal。练习、连接、反馈任务/尝试/结果均0。开发20业务表及迁移记录共21表全行SHA256一致。

两个本轮测试标签已关闭，专属API/Web服务停止，测试库在零活跃连接后删除；8000/8001/7357均关闭。开工752个既有文件全部保留，只更新HANDOFF/本地运行/验证计划3份原文档，其余749个摘要未变；本轮私有凭证、代理、日志和脚本清理结果写入机器摘要。无模型/物理麦克风/原生构建/提交/推送/部署，没有重标此前备份或客户端测试为本轮重跑。
