# 千问 WebRTC 配置门实测

2026-10-29 约 21:50（Asia/Shanghai）。在用户已授权的累计 20 元实验范围内，进行一次实际北京千问 3.8 WebRTC 配置观察，无重试。目的仅为确认真实 WebRTC 配置回包能否通过当前受限协议的配置门，不声称完整语音接入。

临时 loopback 页面在 Edge/macOS 创建原生 `RTCPeerConnection`，预留 sendrecv 音频方向和数据通道，但**没有采集或挂载麦克风及任何音频轨道**；通过本机临时服务调用仓库现有 `QwenWebRtcSignallingGateway`，携带私有配置中的 Key 和 workspace 向固定地域端点交换一次 SDP。临时服务只允许本机同源和一次请求；Key 不进入浏览器。收到 `session.created` 后在同一数据通道发送受限候选的配置，收到 `session.updated` 后立即关闭本地数据通道和 PeerConnection；25 秒是页面本地最长等待，不是服务端失效或停费保证。

页面显示一次请求获得 SDP 答案，连接和数据通道打开，收到 `session.created` 和 `session.updated`，没有观察到错误或超时。所检查的模态、`max_tokens`、音色、提示词、识别模型与 VAD 子字段均匹配，`enable_search` 为 false，`tools` 字段不存在。会话 ID 与返回的 model 没有纳入该页面的匹配检查；不能据此声称当前 Dart 协议的全部配置校验通过。该页面未运行 Dart 协议；当时的协议要求回显空 `tools` 列表，因此该回包不能通过当时的严格门。2026-10-30按供应商回复修订并在实际WebRTC复验，见[新报告](2026-10-30-qwen-reply-and-webrtc-verification.md)。结果由页面可访问性文本人工转录到[脱敏证据](evidence/2026-10-29-qwen-webrtc-config-observation.json)，未记录 SDP、供应商标识、Key 或用户音频。

没有发送 `response.create` 或音频，也没有返回回复用量；实际费用及历史未知费用仍须查询账单，不能把未知记为零。页面显示本地 PeerConnection 已关闭，但不构成服务端已释放、终止计费或能处理客户端崩溃的证据。页面、标签及临时本机服务已关闭和清理。

此次证实候选信令网关在一次实际 WebRTC 交换中返回可建立连接的答案，并观察到 WebRTC 配置也省略 `tools`；未证明语音、实际产品控制器或设备播放、插话、上下文截断、可核验退出和计费。当时默认语音准入关闭；新一次针对供应商回复和真实Dart协议的验证见上述新报告。[官方 WebRTC 指南](https://help.aliyun.com/en/model-studio/realtime-webrtc-access)要求配置确认后再挂载上行媒体；本次全程没有挂载。
