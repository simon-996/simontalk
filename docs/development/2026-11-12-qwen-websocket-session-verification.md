# 千问 WebSocket 会话配置候选

新增未注册、无网络调用的单次服务端协议门：由固定枚举的三个英语难度和两种语速生成与现有 Dart 候选一致的学习提示，设置音频/文字、转写、128 token、禁搜索与受控 server_vad。仅接受合法的 `session.created`，固定模型及会话身份后产生一次 `session.update`；只有不同事件、同 session/model 及关键配置精确回显的 `session.updated` 才标记配置通过。空/缺失 tools 按既有供应商答复处理；null/非空拒绝。状态冲突、重放、错误/重复 JSON、错误格式、嵌套模态、过长事件均失败关闭，不输出供应商原文或会话 ID。

离线目标 30 项，与 PCM 及连接相关共 75 项通过；无真实供应商、真实麦克风或用户内容。嵌套非字符串模态先复现异常泄漏而未关闭，现已修复并回归。固定 PCM 与事件语义依据[阿里云客户端文档](https://www.alibabacloud.com/help/en/model-studio/client-events)和[服务端文档](https://www.alibabacloud.com/help/en/model-studio/server-events)；这批配置门尚未用真实 WebSocket 的完整回显验证，也未接持久 claim 或产品。配置回显不证明自动打断行为、实际播放、上下文与远端退出；正式准入关闭。
