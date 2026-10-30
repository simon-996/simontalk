# 千问WebRTC候选信令边界

日期：2026-10-24。实现：[qwen_webrtc_signalling.py](../../services/api/src/simontalk_api/qwen_webrtc_signalling.py)。当前只完成服务端SDP候选适配，create_app、PracticeAdmission及客户端RealtimeSessionProtocol均保持Unavailable；不因存在代码或API Key而自动开启。

## 官方事实与尚未证明的能力

官方列明workspace地域HTTPS SDP接口，以及当前三种Realtime型号；本模块限定北京地址。[接入说明](https://help.aliyun.com/zh/model-studio/realtime)

公开WebRTC示例的结束逻辑清理端侧媒体和PeerConnection；它不能单独证明上游已结束或费用停止。本轮没有查得覆盖答案丢失/客户端消失的服务端核验依据，保留unknown。[官方示例](https://help.aliyun.com/zh/model-studio/best-practice-webrtc-omni-realtime)

客户端/服务端事件参考尚不足以证明本项目的精确已播前缀与上下文截断确认。这里是核查结果，不能反推供应商绝无相关能力；后续需补正式资料与实测。[客户端事件](https://help.aliyun.com/zh/model-studio/client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/server-events)

## 组合与配置

QwenWebRtcSettings不可变，持有workspace_id、model、config_id及repr隐藏的api_key。workspace必须是最多63位小写DNS label；model只接当前核对的qwen3.5-omni-plus-realtime、qwen3.5-omni-flash-realtime、qwen3.8-omni-flash-realtime；允许这些名称不代表实际账号有权限或已验证模型效果。config_id仅1–128位ASCII标识，密钥仅1–4096个可见ASCII字符，无空白/CRLF。

check_configuration只接受完整且精确相等的四字段：provider=dashscope、region=cn-beijing及原model/config_id；不允许传endpoint或其他字段。失败503，未建立HTTP客户端。offer沿用已有65,536字节、UTF-8、无NUL和v=0换行门；非法输入在I/O前422。

只有可信服务端组合代码可提供client_factory。生产默认每次创建独立HTTPX client/transport；该参数不来自HTTP请求或账号偏好。长期密钥仅作为上游Authorization头，不进入PracticeSession/connection配置或客户端回复。

## 一次性交换

固定目标为https://{workspace_id}.cn-beijing.maas.aliyuncs.com/api/v1/webrtc/realtime，仅model查询参数。POST原始UTF-8 offer；Accept/Content-Type为application/sdp，Accept-Encoding为identity。HTTPX client与transport均trust_env=False，transport retries=0，请求明确follow_redirects=False。

单次HTTP阶段（包括body读取和资源关闭）受7秒协作取消边界保护，上层现有8秒exchange边界保留；不改变数据库claim/完成事务或客户端12秒总等待。HTTPX的异步stream上下文负责关闭；环境代理/环境CA配置不参与默认client。[HTTPX异步接口](https://www.python-httpx.org/async/)、[环境变量](https://www.python-httpx.org/environment_variables/)、[Transport重试](https://www.python-httpx.org/advanced/transports/)

只接受200/application-sdp及无压缩/identity；不读取非成功错误正文。Content-Length若存在须合法、≤65,536且与实际字节一致；按原始分块读取，超限立即拒绝，不累计后续块。严格UTF-8解码并重验SDP基础格式；不持久化正文。

TimeoutError/HTTPX超时转固定安全TimeoutError，既有服务映射504/signalling_timeout；其他网络/格式错误为固定QwenSignallingFailure，既有服务映射502/signalling_failed。异常在except之外重新抛出，原SDK异常的context/正文不跨边界。外部CancelledError原样传播，不变成可重试成功。

每次方法调用只执行一次HTTP；业务层既有每连接claim、摘要防重、重启409和unknown核验继续生效。这个适配类不单独承担跨请求去重，也不具备终止确认或占用释放权限。沿用[单次信令契约](2026-10-17-guarded-signalling-api.md)。

## 验证和继续条件

[验证报告](../development/2026-10-24-qwen-webrtc-signalling-verification.md)区分79项组件测试、实际ASGI/SQL组合、隔离流程演练和无pytest运行环境。供应商HTTP为MockTransport；演练文字与反馈是明确样本，无真实设备、语音、模型质量或上游退出证据。

HTTPX0.28.1由已有dev提升runtime，锁中38个包版本不变；不引入供应商SDK，不改schema。后续需要账号/workspace/地域/模型权限和允许预算，以及可信退出、截断/播放对齐和设备网络实测；条件满足后才能选择准入工厂、客户端协议与正式通话页。当前B2/B5/B6继续未完成。

2026-10-24后续完成[准入资料复核](../development/2026-10-24-qwen-realtime-readiness-review.md)：官方通用WebRTC页与最佳实践的媒体门控时序、Omni总览与专门事件表的finish定义存在差异；继续保持配置确认后上行，不补造finish、播放前缀或截断确认。另核RTC智能体控制面作为独立产品候选，未替换当前路线。当前浏览器页面及合成回环的新增证据见[实测](../development/2026-10-24-browser-acceptance-verification.md)，不替代真实供应商/终止实测。
