# 受限单次信令交换

日期：2026-10-17。按持续开发授权推进供应商无关的业务信令边界；不选择/启用模型账号，不调用付费服务，不增加无法对话的页面。

## 方案与范围

现有RealtimeTransport等待RealtimeSignaller，后端尚无安全交换入口。直接让客户端连供应商会暴露鉴权/目的地控制；先拼供应商协议需要尚未提供的权限与终止证据。采用业务后端单次信令用例和客户端独立HTTP signaller，实际运行同时保留UnavailableAdmission与UnavailableSignallingGateway；只有独立测试库可注入明确替身。真实网络适配、配置确认及媒体协调器仍待后续。

## 接口与持久证据

POST `/v1/practice-sessions/{sid}/connections/{cid}/offer`接收严格client_instance_id、epoch和offer；不接受客户端目标URL、凭证、模型或状态。沿用认证、Web Origin/CSRF/X-Account-ID。JSON最多96KiB、SDP UTF-8最多64KiB，总读取时间5秒；不信任Content-Length，先有界读取再解析。

User→Practice→Connection加锁后重验身份、所有权、当前代次/客户端、父状态、未到期租约、原始公开配置与当前本地准入，网关本地配置检查也必须通过，并绑定通过检查的同一实例。先事务提交negotiating/unknown、offer SHA-256和开始时间，随后释放所有数据库锁再调用网关。每连接只允许一个offer；相同请求重复也返回409，不自动再次调用上游。SDP和Answer只在请求内存，不写数据库或日志。

网关异步交换总限时8秒。成功返回Answer前重新锁定并检查原尝试、代次、租约、父状态和登录/准入；有效才进入configuring并返回与请求一致的session/connection/client/epoch及answer，不发布ready。失败、超时或无效答案将原negotiating尝试置unknown并保持占用；授权丢失也丢弃答案。扫描、取消或其他操作已改状态时不覆盖，不因晚到结果复活。进程在外部调用后退出时，已提交意图仍保持占用，由扫描转unknown。

新增offer_digest、signalling_started_at/finished_at及一致性约束；只保存摘要和时间。数据库禁止带已开始信令摘要的记录改回not_started终止证据。旧数据/测试媒体种子可无摘要，不把它们升级为真实调用证据。没有答案缓存；已尝试连接的丢失答案不能通过重发再开会话，待可信终止流程处理。

## 客户端

ApiRealtimeSignaller实现已有接口，每实例只发送一次offer。通过ApiClient派生独立HTTP客户端，同时引用原账号当前身份，CSRF/凭证/响应等待后仍检查身份；每请求中止信号覆盖响应体读取，取消只能关闭自己的请求通道。总等待12秒，取消立即结束等待，迟到响应被丢弃，不关闭共享账号客户端，不自动重试。

检查响应session/connection/client/epoch和答案边界，错误只返回稳定code，不输出SDP/凭证。暂不把信令前PracticePreparationController用于已发SDP连接，也不自动开启麦克风或页面。

## 验证

先测默认503无意图/调用、身份/所有权/代次/租约/配置、严格体积/时限、重复和并发至多一次；网关替身从独立事务观察到持久negotiating且可取得所有锁；失败/超时/撤销/晚到结果保持unknown，DB不保存原SDP，错误不泄露输入。客户端覆盖单次、取消/超时/晚到、账号变化与共享客户端存活。实测使用独立PostgreSQL及HTTP/网关替身，明确不代表供应商媒体或费用验收。
