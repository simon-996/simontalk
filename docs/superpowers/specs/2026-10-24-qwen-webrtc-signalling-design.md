# 千问WebRTC候选信令适配

日期：2026-10-24。按持续开发授权推进B2接入底座；沿用D10候选，不改变供应商准入决定，不调用真实模型。当前功能分支已有全部前置实现，继续在原工作区集成并保存全文件摘要，不另建缺少未提交前置代码的worktree；不提交/推送/部署。

## 官方核对与边界

官方接口给出workspace地域HTTPS地址，POST原始SDP并返回Answer；凭据须由业务后端持有。[接入说明](https://help.aliyun.com/zh/model-studio/realtime)

官方WebRTC示例的关闭过程清理本地轨道和PeerConnection；本轮未查得可覆盖答案丢失/客户端消失的服务端核验接口，不能据此释放业务unknown。[示例](https://help.aliyun.com/zh/model-studio/best-practice-webrtc-omni-realtime)

事件参考没有给出本项目所需的精确已播放前缀/上下文截断确认保证；当前公开事件的缺失不等于供应商绝无能力，需后续正式核查与实测。[客户端事件](https://help.aliyun.com/zh/model-studio/client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/server-events)

因此本单元实现可调用的后端SignallingGateway适配类，但create_app、准入、配置工厂和客户端协议保持Unavailable。它不具备单独开启正常语音的权限。真实账号地域、预算和退出实测继续按既有暂缓安排；浏览器工具本轮仍因Work设置禁用。

## 本次方案

候选A：先接完整媒体，需要尚未证明的终止/截断和实际设备条件。候选B：先交付有界SDP网关，复用当前一次性claim和unknown处理，可完成独立工程验证。采用B；后续仍由B2能力关卡决定是否接准入。

新增QwenWebRtcSettings（不可变、密钥repr隐藏）、QwenWebRtcSignallingGateway和固定异常。只支持北京地址，workspace作为严格小写DNS label、模型限定官方当前三种Realtime名称、config_id限定ASCII标识。配置四字段必须与本次permit逐项相等；错误在创建HTTP客户端前503。SDP沿用65,536字节/UTF-8/NUL和v=0换行门。

每次交换用独立httpx.AsyncClient，默认trust_env=False、不跟随重定向、不重试、禁用环境代理；整个请求含读取/关闭共7秒，上层既有8秒仍保留。只接收200/application-sdp/identity编码，Content-Length格式/上限/实际长度均核对，增量原始字节最多65,536，严格UTF-8和SDP基础校验。非成功不读取错误正文，不持久化SDP/密钥。超时转安全TimeoutError供既有504处理；其他错误为固定异常，取消原样传播，释放HTTP资源。

httpx从现有dev依赖提升到runtime，保持锁中0.28.1及其他包版本，不引入SDK或升级。factory注入只供内部测试/组合；生产默认client固定网络选项。

## 完成标准

构造静默，配置/输入拒绝零客户端；固定URL/方法/请求头/原字节、成功、多种HTTP/格式/编码/长度错误、分块超限、超时和取消关闭、异常脱敏、默认app仍关闭全部有证据。先RED后实现，独立只读复核；隔离数据库回归既有claim/unknown及默认拒绝，开发数据不变。文档分别标明官方事实、未证实能力和替身结果，不能称真实千问接通。
