# 账号与个人偏好接口契约

日期：2026-10-15。用于本次前后端工程实现，持久化数据使用 PostgreSQL。

## 通用约定

- 前缀 /v1；请求和响应为 JSON。错误统一含 code、message、request_id，响应头提供 X-Request-ID，不回显密码、凭证或原始输入。
- 用户名规范化为小写，3–32 位 ASCII 字母/数字/下划线，首位为字母；展示名 1–60 字符；密码 12–128 字符，允许粘贴和密码管理器。
- 时间保存为 UTC；登录 7 天、邀请码 72 小时一次、密码重设 15 分钟一次。
- Web 仅 Cookie 身份，HttpOnly、SameSite=Lax；生产必须 Secure。本地开发允许明确的 HTTP 环境。移动端使用 Bearer token，安全存储；Web 不把业务 token 存 localStorage。
- 客户端从注册/登录或 GET me 得到本人ID后，对偏好GET/PATCH及退出携带 `X-Account-ID`。服务端将其与实际凭证身份比较；Web已认证的PATCH/退出必须提供，缺失或不匹配返回 `409 account_changed`，不执行原动作。失效身份退出仍幂等204。客户端重新识别当前账号，按用户ID重置草稿并提示确认，不自动重放旧操作，防多标签共享Cookie串改设置。
- Web 先 GET /v1/auth/csrf，得到 csrf_token JSON 和配对 Cookie；状态改变请求使用 X-CSRF-Token。服务端校验 Cookie/header 和允许的 Origin。跨来源默认拒绝，开发仅允许配置的 localhost/127.0.0.1 Web 来源；移动 Bearer 无需浏览器 CSRF。
- 同一客户端及其账号作用域HTTP分支共享CSRF缓存与进行中的获取，避免轮换共享Cookie使兄弟请求使用旧令牌；各分支仍独立取消。csrf_invalid只清除仍匹配该请求令牌的缓存，不自动重放。不同页面的轮换仍可能导致拒绝，由本人明确重试。
- 本地 API 127.0.0.1:8000，Web 开发端口 7357。Android 模拟器 API 地址用 10.0.2.2:8000，真机地址通过非密钥构建参数配置。

## 数据形状

User：id（UUID 字符串）、username（规范化）、display_name。

Preferences：difficulty 为 null 或 beginner/intermediate/advanced；speech_pace 为 normal/slow；subtitle_default、chinese_hints_enabled 为布尔值；translation_mode 仅 on_demand；version 为正整数。

新用户偏好默认 difficulty=null、speech_pace=normal、字幕与中文提示开启、translation_mode=on_demand、version=1。进入应用后首次明确选择难度，保存成功再进入个人偏好页。

## 接口

| 方法 | 路径 | 输入与结果 |
| --- | --- | --- |
| GET | /health/live | 200 {status: ok}；不依赖数据库 |
| GET | /health/ready | 数据库可查询时 200；不可用时 503，不泄露连接信息 |
| GET | /v1/auth/csrf | 200 {csrf_token: string} 并设置配对 Cookie |
| POST | /v1/auth/register | invite_code、username、password、display_name、platform（web/mobile）；201 {user: User}；mobile 另含 access_token，web 仅设置会话 Cookie |
| POST | /v1/auth/login | username、password、platform；200 与注册同样响应结构；错误统一 401 invalid_credentials |
| POST | /v1/auth/logout | 撤销当前会话，清 Cookie；204；重复退出安全 |
| POST | /v1/auth/password-reset/confirm | reset_token、new_password；204，原子消耗、更新密码、撤销全部会话与其他重设凭证；不接收目标用户 ID |
| GET | /v1/me | 200 User；未登录/过期/撤销/禁用账号返回 401 |
| GET | /v1/me/preferences | 200 Preferences |
| PATCH | /v1/me/preferences | 必填 version（预期当前版本），允许修改五个偏好字段；200 新 Preferences；版本冲突 409 preferences_conflict；不改他人数据 |

错误码：invite_invalid（400）、registration_failed（400，避免区分已存在账号）、reset_invalid（400，无效/过期/已用重设凭证）、request_error（对应 HTTP 错误）、invalid_credentials（401）、unauthorized（401）、csrf_invalid（403）、origin_forbidden（403）、preferences_conflict（409）、validation_error（422）、rate_limited（429）、service_unavailable（503）。

邀请码消耗与用户/偏好创建在同一事务；重复及并发注册不能复用邀请。偏好更新使用数据库原子版本条件。账号接口包含按 IP 和账号维度的有界限流，重试不造成无限日志或未清理计数。所有身份查询只使用当前凭证的 user_id。

维护操作由受本地环境权限保护的 CLI 完成：创建单次邀请、签发单次密码重设凭证、禁用账号。不提供查看朋友对话的管理 API，不自动发送短信或邮件。

## 客户端行为

- 会话启动先读取移动端安全凭证或 Web Cookie，获取本人和偏好。401 回登录；网络失败显示重试，不静默清除有效凭证。
- 登录、注册、重设提交期间禁止重复操作，成功后清空密码和一次性凭证输入。移动端退出清理本机凭证并尽力撤销服务端会话；撤销失败必须清楚说明。Web 的 HttpOnly Cookie 只能由服务端清除，退出失败时保留当前状态、明确提示并提供重试，不声称已退出。
- 修改偏好失败保留选择并提示未保存。409 重新加载服务端实际版本并提示用户核对，不能覆盖他人或旧版本。
- 本批只提供真实账号与偏好界面，不伪造通话、话题记录或学习成绩。语音功能在后续真实接入时增加。
