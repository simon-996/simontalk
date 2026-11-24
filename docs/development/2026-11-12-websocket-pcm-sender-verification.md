# 浏览器 PCM 发送与本机 WebSocket 合成链路

新增未注册的浏览器发送控制：调用方负责提供已经授权的 socket、capture 和同步释放实际媒体轨道的回调；组件不创建连接、不申请麦克风或取得凭据。默认静音，解除静音先发 mode 后开启 capture；静音先本地阻断并关闭 capture 交付，再发送 mode。音频使用独立 PCM wire 帧与单调序号，缓冲超 32768 字节、socket 异常、页面隐藏/离开或编码错误均失败关闭；停止/错误尽力关闭 capture、释放调用方媒体并关闭 socket。已交给浏览器或网络的字节不可撤回。

浏览器 JS 定向 4 项、Node Web 全量 111 项通过，覆盖初始静音、控制/音频顺序、背压、背景/断线、同步重入和媒体释放；Web release 构建通过且发送脚本源码与产物哈希一致。Edge 中使用 16 kHz 振荡器→MediaStreamDestination→实际 AudioWorklet/capture→发送控制→本机 WebSocket→服务端 wire/PCM relay→假供应商的组合：第一次发送 6 帧，静音期间仍 6 帧，恢复后 10 帧，停止后仍 10 帧；服务端收到的模式为 1/开、2/关、3/开，对应代数分别转发 6 和 4 帧、32000 字节，收到 stop 并关闭假供应商，调用方音轨 ended、AudioContext closed。见[结果](evidence/2026-11-12-pcm-loopback.json)、[页面](evidence/2026-11-12-pcm-loopback.html)和[本机服务](evidence/2026-11-12-pcm-loopback-server.py)。本机测试 socket 仅限制回环地址和 Origin，并没有模拟数据库鉴权；未使用真实麦克风、真实供应商、API key 或保存原始音频。

本单元尚未接产品页面或真实认证路由；调用方必须自行绑定当前账号、处理换号、确保服务端明确就绪及同步释放真正媒体轨道。网络中已缓冲的数据仍可能先于关闭到达。合成链路不证明真实人声/播放/插话、端到端业务记录或可信上游终止，正式语音准入继续关闭。
