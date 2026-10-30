# 会话过期、账号禁用与登录限流浏览器补验

日期：2026-10-25，Asia/Shanghai。依据既有[账号契约](../architecture/2026-10-15-account-api.md)及[执行计划](../superpowers/plans/2026-10-25-browser-session-boundaries.md)，补实际页面与真实HTTP/SQL组合证据。没有修改应用源码、依赖、schema、安全规则或限流配置；当前release晚于111份lib Dart源码，开始/结束摘要一致，未重建或重跑无关全量。此前Flutter1401/10skip、Node58、API975等为历史检查。

## 环境与证据范围

桌面IAB → loopback7357同源代理 → 默认供应商关闭的API8001 → 专属`simontalk_session_boundaries_20261025_f37a2_test`。A/B/C通过真实API临时注册并各选一个难度，均为v2/normal；不是开发账号。127.0.0.1与localhost分别保留B/C的Cookie范围，沿用已有允许来源。

23条浏览器请求全部转发真实API，无代理伪造错误；元数据仅含方法、路径、状态、错误code、耗时、阶段与Retry-After，无正文/Cookie/密码/token。另有独立直接HTTP种子、两批各9次错误登录、旧移动会话读取及B登录，与浏览器操作分开，见[机器摘要](evidence/2026-10-25-browser-session-boundaries.json)。

| 场景 | 实际结果 |
| --- | --- |
| 会话过期时保存旧草稿 | A登录后选advanced草稿；仅在测试库把A当前Web会话expires_at设到过去。浏览器PATCH401 → GET me401 → /login；服务端仍v2/intermediate/normal，A移动会话GET me200 |
| 过期后重新登录 | A真实登录200，首页仍自然交流，旧advanced草稿未提交 |
| 维护禁用账号 | A再次选advanced草稿后调用已有disable_user；A三个历史/当前会话全部撤销。浏览器旧保存401→恢复401→/login，正确密码登录也401/invalid_credentials；旧移动会话401 |
| 独立账号 | B浏览器登录200，偏好仍v2/beginner/normal且无A草稿；C受限后B另经直接HTTP登录200，最终B浏览器刷新me/preferences均200 |
| 真实账号限流 | 默认账号10次、IP30次、窗口600秒未改。先直接HTTP预填C的9次错误401；浏览器第10次401、第11次429，显示操作过频、输入保留且提供明确登录按钮，无C Web会话 |
| 正确密码下限流复验 | 首次过期重试因自动化输入错误401，不计恢复证据；纠正输入后再通过9次真实HTTP错误将桶补至10，浏览器已核对正确密码仍429。两次429均带Retry-After:600，桶计数封顶11、C Web会话仍0 |
| 过期限流恢复 | 仅将C账号限流桶expires_at预置过去，保持IP桶及所有配置；同一表单明确重试200，正确进入advanced首页，C新桶attempts=1 |

预置过期属于故障注入，不是等待七天会话或600秒限流窗口自然到期。限流返回的600是现有服务端头部值，不等于此次实际等待时长或剩余倒计时；客户端没有自动重试。

## 页面与过程限制

五张1280×720桌面视口截图已逐张查看：[会话过期回登录](screenshots/browser-session-expired-login.jpg)、[禁用账号登录拒绝](screenshots/browser-session-disabled-login.jpg)、[B独立偏好](screenshots/browser-session-independent-b.jpg)、[最终正确输入下的429](screenshots/browser-session-rate-limited.jpg)、[限流过期后登录](screenshots/browser-session-rate-recovered.jpg)。保存图中密码均隐藏。

首次限流过期后重试出现401。自动化在语义输入框切换时未完整清除旧密码，显示合成测试值后确认了插入拼接；没有把这一试次判成服务端恢复缺陷。用当前截图坐标点入真实输入框、全选/清空并完整重填后，实际核对正确值，再隐藏密码，完成429→预置过期→200复验。未把脱敏DOM值当作真实密码比对证据；请求摘要第18条作为排除试次保留。没有将明文测试密码截图写入仓库。

本轮未发现需要修改应用源码的确定问题。过期和限流桶有明确测试注入，未演练自然长时到期、IP限流上限、限流全部维度/并发、精确浏览器版本、手机、辅助技术或大陆真实网络。B2/B5真实供应商与B6仍未完成。

## 数据与清理

最终3用户/3邀请/8会话，A禁用且3个会话已撤销；B/C共5个会话保留到本轮清理。三账号偏好分别为intermediate/beginner/advanced，均v2/normal，无旧草稿写入；密码重设凭证、练习、连接、反馈任务/尝试/结果均0。开发20业务表及迁移记录共21表全行SHA256不变。

两个本轮测试标签已关闭，API/Web服务停止，专属库确认零连接后删除，8000/8001/7357均关闭。开工762个既有文件保留；只更新HANDOFF/本地运行/验证计划3份原文档，其余759个摘要不变。本轮私有凭证、脚本与日志清理结果写入机器摘要；没有模型/物理麦克风/原生构建/提交/推送/部署。
