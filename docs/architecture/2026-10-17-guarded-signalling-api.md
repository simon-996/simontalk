# 受限单次信令契约

日期：2026-10-17。实现供应商无关的交换边界和客户端HTTP适配；实际运行的准入与信令网关均固定关闭。成功路径通过独立PostgreSQL测试库及明确网关替身验证，没有调用模型或证明媒体终止/费用可控。

## HTTP与输入

`POST /v1/practice-sessions/{sid}/connections/{cid}/offer`需要现有登录。Web沿用允许的Origin、CSRF和X-Account-ID。输入仅含client_instance_id(UUID)、epoch(严格正整数)和offer(字符串)，不接受目标地址、凭证、模型配置或状态。此接口不使用创建登记的Idempotency-Key，也不自动重试。

| 边界 | 处理 |
| --- | --- |
| 请求体 | ASGI按实际分块累计，最多96KiB；不信任Content-Length，超限413 request_too_large |
| 接收时间 | 收完整个请求体最多5秒，超时408 request_timeout；此限时不包含发送错误响应 |
| SDP | UTF-8最多65,536字节，以v=0加换行开始，不含NUL；非法输入422。只做基础格式检查，供应商/浏览器负责语义验证 |
| 响应 | 200包含session_id、connection_id、client_instance_id、epoch、answer；身份字段必须对应原请求，答案适用同一SDP边界 |
| 错误 | 沿用稳定code/message/request_id、X-Request-ID、no-store和允许来源的CORS；不回显SDP或SDK异常 |

## 持久意图与并发

准备事务按User→PracticeSession→RealtimeConnection加锁，等待User锁后重验身份，再核对所有权、当前代次/客户端、父状态connecting、连接preparing/not_started、未到期租约、历史配置与当前准入。网关check_configuration只允许本地配置检查；绑定通过检查的同一个网关实例后，才提交negotiating/unknown、offer SHA-256和开始时间。

事务提交并释放数据库锁后，调用一次异步exchange_offer，等待上限8秒。将来接入的适配器必须支持取消，不重试、不跟随客户端目标地址或重定向；该协议尚未经过真实供应商SDK验证。业务租约继续由服务端时间决定，不因交换自动延长。

每连接只接受一个offer。重复相同摘要为409 signalling_already_attempted，不同摘要为409 signalling_offer_conflict；并发或进程重启不会再次交换。没有答案缓存；已交换但客户端未收到答案时不能靠重发建立新上游，需后续可信终止/恢复流程。

完成事务重新按相同顺序加锁，核对原连接、代次、客户端、摘要及negotiating/unknown状态，并重验登录会话、准入、配置和租约。成功仅进入configuring，不表示ready、模型配置确认或声音已播放。扫描或其他操作已改变状态时返回409并丢弃答案，不覆盖新状态。

| 结果 | 持久行为 |
| --- | --- |
| 有效答案 | configuring/unknown，记录结束时间与answer_received |
| 网关异常、无效答案、8秒超时 | unknown/unknown，练习interrupted，无ended_at；分别502 signalling_failed、502 signalling_invalid_answer或504 signalling_timeout |
| 身份/准入/配置丢失或租约到期 | 丢弃答案，保持unknown占用；返回对应401/409/503 |
| 请求取消、进程退出或完成事务失败 | 已提交的negotiating/unknown仍占用；到期扫描保守转unknown，不推断上游终止 |

数据库仅新增offer_digest、signalling_started_at、signalling_finished_at，约束摘要/时间一致且已有摘要不能改回not_started。不持久化原Offer/Answer，不记录SDK异常。旧媒体测试种子允许没有摘要，不能当作真实上游证据。取消准备和自动清理不能释放已提交信令意图。

## 客户端HTTP所有权

ApiRealtimeSignaller实现已有RealtimeSignaller接口，每实例绑定账号、练习、连接、客户端及代次，只发送一次。通过ApiClient.forkForAccount持有独立http.Client，同时动态读取源账号身份；CSRF、凭证和响应等待后继续检查，源客户端关闭也使派生身份失效。每条HTTP请求使用AbortableRequest和独立中止信号，覆盖收到响应头之后的流式响应体；关闭作用域时触发全部在途信号，请求完成/超时后移除。取消/超时立即结束本地等待，只关闭自己的HTTP客户端，迟到响应不再返回答案。

12秒总等待覆盖CSRF/凭证/HTTP全过程；本地取消和HTTP断开均不能证明服务器未交换或供应商已终止。客户端还核对返回的四项身份和答案边界；失败后需读取服务端当前状态，不自动重放。

该适配尚未接到页面或媒体协调器。现有PracticePreparationController只管理信令前准备，不可直接复用来控制已发SDP的媒体连接；配置确认、后台/账号变化/业务失联时的媒体释放及可信上游终止仍待后续。

实现方案见[设计](../superpowers/specs/2026-10-17-guarded-signalling-design.md)，实测见[验证记录](../development/2026-10-17-guarded-signalling-verification.md)。
