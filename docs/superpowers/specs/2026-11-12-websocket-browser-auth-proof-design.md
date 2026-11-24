# 浏览器 WebSocket 一次性首消息凭据候选

复用 ApiClient 已有共享 CSRF 请求与 HttpOnly Cookie 机制，为未来的同账号 WebSocket 握手生成首消息，不开放路由、创建 socket 或输出日志。只支持 Web，必须提供当前账号的规范小写 UUID；获取 CSRF 前后均核验账号和调用方生命周期。CSRF 必须符合后端预检的 URL-safe 32–256 字符格式。

返回一次性对象，不在 `toString` 暴露任何 token。调用方紧邻已授权 socket 的 send 同步调用 consume；消费时再次校验原账号及生命周期，一次性销毁本地 token；重复消费、客户端关闭、账号变动或不再有效均拒绝，绝不复用旧对象。JSON 仅含 authenticate、account_id 和 csrf；不得放入 URL/子协议/日志或长期持久化。CSRF 请求的 cookie 仍由浏览器承载，本对象不替代服务端数据库身份及 claim，不能阻止发送后换号；客户端仍必须监听账号并关闭实际媒体。
