# 千问工单答复与 Dart WebRTC 配置验证

2026-10-30（Asia/Shanghai）。工单答复由用户转述；本轮没有独立读取工单页面。以下区分供应商说法、官方文档、本机观察与尚未证明的条件。

## 供应商答复

用户转述阿里云表示：3.8 Omni 的 `response.done` 返回 usage 并据此计费；没有事件返回且不产生 usage 结果则不计费；可调用 `RealtimeSession.close()` 结束会话，没有撤销入口；请求参数不设置 `tools` 不会触发工具调用；播放打断需客户端实现，上下文可参考示例并上报更新，效果需实际验证；不支持播放对齐；`max_tokens` 仅限制单次输出 Token，不影响输入。

这些回答没有说明：本地未收到事件是否能证明供应商侧未产生 usage；客户端崩溃、SDP 回包丢失后的独立会话查询或可信远端失效时点；更新后未播放内容一定排除在模型后续上下文之外；音频 Token 是否计入该型号输出限制。因此不把这些结论推定出来，也不声称具备金额硬上限或可信远端退出。官方[模型文档](https://help.aliyun.com/zh/model-studio/realtime)分别建议 WebSocket 调用 `close()`、WebRTC 停止媒体并关闭 PeerConnection；本地关闭不自动等同异常失联后的服务端终态核验。

## 代码调整

按上述明确的工具规则，`QwenGuardedProtocol` 发出的 `session.update` 不再包含 `tools`；服务端回包的 `tools` 字段可以缺失或为空列表，若为非空、null 或错误类型则拒绝。`enable_search:false`、型号、会话身份、模态、音色、提示词、识别模型、VAD 和输出 Token 限额的校验仍保留。没有因此注册正式协议工厂或开放生产准入。旧记录没有保存搜索字段，仍不能直接当成完整真实配置回放；另行补充模拟字段的回放明确标记为模拟。

两个新增测试先分别复现请求仍携带 `tools`、缺少 `tools` 回显时拒绝就绪，修正后通过；另覆盖空列表、非空列表、null、错误类型及搜索启用，既有双通道、控制器与收尾测试一起通过。

## 实际 WebRTC 配置实验

本机一次独立 Edge/macOS WebRTC 连接，以 Flutter Web 编译当前真实 Dart `QwenGuardedProtocol`，通过本机一次性服务调用仓库真实 `QwenWebRtcSignallingGateway`；按原练习配置构造候选，页面仅负责 WebRTC 和回调桥接。一次连接、一次 SDP 请求，无自动重试；预留音频方向，但未申请麦克风、未挂任何音频轨道、不发送音频、不请求模型回复。

页面观察到：连接建立，三个数据通道打开且包括服务端 `txt`；收到 `session.created` 后，Dart 沿原通道发送 `session.update`，请求未带 `tools`；回包 `enable_search:false` 且无 `tools`；Dart 完成全部配置校验并从原通道回调 `confirmConfigured`，随后本地关闭。证据为页面可访问性文本人工转录，见[脱敏 JSON](evidence/2026-10-30-qwen-dart-webrtc-config.json)；没有保存原始 SDP、会话 ID、密钥或音频。

这次确实运行了当前 Dart 协议和真实信令网关，但没有运行产品的 `PracticeMediaController`、实际麦克风或完整对话；`confirmConfigured` 是协议配置确认，不是正式媒体启用、自然插话、播放对齐或上游退出验收。本地关闭不是供应商释放/结算证明。实验没有请求任何回复，未返回回复 usage；实际账单未独立核对。本次试验纳入此前累计 20 元授权，预算不是已验证的供应商硬停费机制。

最终相关测试67项通过；Flutter全量1486项通过、10项专用夹具跳过；静态分析、229个Dart文件格式及Web release构建通过（编译64.0秒）。临时页面、服务、浏览器标签和临时编译入口已清理。
