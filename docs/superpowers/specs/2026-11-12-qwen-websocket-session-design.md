# 服务端千问 WebSocket 会话配置候选（待实现）

服务端持有上游连接时，必须自行生成并核验配置，不能信任浏览器或直接透传任意 `session.update`。候选沿用现有 Dart `QwenGuardedProtocol` 的固定英文角色说明、三个难度、normal/slow 两种语速、128 token、Tina、音频+文字、搜索关闭、转写模型及受控 server_vad；参数仅由持久化练习快照映射，不插入用户文本。上行 PCM 格式为 16 kHz 单声道小端 PCM16；输出按供应商事件的 24 kHz PCM 路由。具体事件见[阿里云客户端事件](https://www.alibabacloud.com/help/en/model-studio/client-events)及[服务端事件](https://www.alibabacloud.com/help/en/model-studio/server-events)。

单个对象只接一次 `session.created`，需合法唯一事件 ID、model 与会话 ID；仅构造一次 `session.update`。接收配置确认前不准许语音/对话事件；`session.updated` 必须不同事件 ID、同一 session ID/model、音频与文字模态、全部必要配置值精确匹配。根据既有供应商答复，未请求 tools 时回显只允许缺失或空数组；null/非空拒绝，`enable_search` 必须 false。无效、重复、超长、错误、类型混淆一律封闭，错误不含事件正文和 session ID。回显配置本身并不证明上游实际执行、人工听见、上下文裁剪或远端退出。

组件只做本地协议确认，不能代替持久 claim、连接身份复验、收发有界生命周期、用户授权与真实供应商实测；本阶段不开放正式准入。
