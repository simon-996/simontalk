# SimonTalk Client

Flutter 客户端，当前以 Web 为主，Android/iOS 工程保留，原生构建暂停。已实现账号、个人偏好、本机麦克风检查、WebRTC传输底层，以及练习/连接登记的HTTP仓库与准备生命周期。真实语音准入关闭，尚无练习页面或供应商接入。

准备模块位于`lib/features/practice/`，账号绑定的provider仅在消费时创建控制器，不自动发请求；详见[客户端准备契约](../../docs/architecture/2026-10-17-client-preparation-lifecycle.md)、[本地开发](../../docs/development/local-development.md)与[交接](../../HANDOFF.md)。
