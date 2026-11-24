# 浏览器媒体 WebSocket 握手候选

目的：为后续账号绑定的媒体 WebSocket 定义严格预检，不注册路由，不建立供应商连接、不修改既有 HTTP 认证，也不声称此预检已经认证。浏览器 WebSocket 不便设置任意请求头；将现有 csrf 响应令牌放在 TLS 下 WebSocket 的首个小 JSON 消息中，不放 URL、子协议、日志或错误。生产部署前需确认反向代理、ASGI 消息限长及日志配置。

仅接受服务端精确允许的单个 Origin、无查询串、无 Authorization 且恰好一个 Cookie 请求头。只解析该头中的 session/CSRF cookie；缺失、重复、畸形或非 ASCII 失败关闭。首消息严格 UTF-8、最多 1024 字节、JSON 不得重复字段，字段仅 `type=authenticate`、`account_id`（规范小写 UUID）和 `csrf`（与 cookie 常量时间匹配）；限定令牌格式和长度。结果只携带账号 UUID 与 session 摘要，repr 也不输出摘要，固定错误不泄露输入。类型和值不满足均拒绝。

仅凭该结果绝不能启动媒体：调用方仍须在独立截止内取得首消息、验证数据库会话未撤销/未过期、用户有效且与 account_id 一致，并以事务锁校验练习、连接、attempt/epoch、一次性准入和供应商配置；仅在持久化标记后才能建连。连接运行期间仍须处理会话撤销、账号更换、客户端断开、关闭和远端未知。禁止将首消息正文或 cookie 作为错误/监控字段。
