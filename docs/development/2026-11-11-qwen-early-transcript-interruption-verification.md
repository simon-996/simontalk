# 千问 WebRTC：插话增量先于开始事件

2026-11-11（Asia/Shanghai）。在此前累计 20 元授权内进行 5 次独立、各限一次 SDP 交换的实测；浏览器为 macOS Edge 157.0.4341.46。每次使用固定合成语音，输出从创建起静音，无物理麦克风；真实 Dart `PracticeMediaController`、`QwenGuardedProtocol`、浏览器传输及仓库信令网关参与，账号、练习与连接登记为本地替身，不连接正式数据库或产品页面。每次在第一条用户语音和模型回复后，观察到远端非静音信号才发送第二段合成语音；标识和正文只在内存中使用，证据只记录事件名、时间、布尔量和用量。

## 发现

前 3 次使用修改前协议。在第一条用户语音完成、助手回复已创建并观察到远端音频信号后，新的用户转写增量到达时尚未观察到第二次 `speech_started`；协议因不接受此顺序关闭，未压制输出或发送取消。其中第 3 次通过内存中比较确认增量关联的用户项不同于第一项，见[身份核对](evidence/2026-11-11-qwen-controller-interruption-identity.json)。另外两次见[首次](evidence/2026-11-11-qwen-controller-interruption.json)和[事件诊断](evidence/2026-11-11-qwen-controller-interruption-diagnostic.json)。这三次未收到回复终态或 usage，费用和远端退出未知。

第 4 次使用修改前协议，但诊断页在新的转写增量到达时停止向 Dart 控制器转发后续事件，仅继续观察原始数据通道，最多等待 8 秒；没有发取消或新回复。同项的 `speech_started` 在首个增量约 76 毫秒之后到达，随后停止、提交和最终识别均匹配。原回复在开始事件之前竞争完成（`completed`）；本地连接替身续租返回错误，控制器约 15 秒时关闭，发生在同项最终识别之后。这个诊断只说明该次实际事件顺序，不是产品协议成功处理。返回 usage 795 Token，见[顺序证据](evidence/2026-11-11-qwen-controller-interruption-order.json)。

[阿里云服务端事件说明](https://www.alibabacloud.com/help/en/model-studio/server-events.md)将语音开始事件定义为服务器检测到起始，将转写增量定义为说话时的中间识别；实际顺序应以本次事件为准，不能推断所有网络及会话都相同。

## 修补与复测

归一化器新增仅由协议显式启用的受限路径：严格验证非空转写、用户项与事件身份，原子建立用户话轮并保存增量；默认路径保持原有规则。协议仅对已经绑定、尚未结束的原助手回复和一个新用户项启用，验证完成后先压制旧输出、登记用户话轮，再经原受保护通道最多取消一次。迟到的同项开始事件允许验证和精确重放，错项、冲突、空/无效增量失败关闭。原有结束、账号变化和固定尾部截止仍有效；输出仍保持隔离，不发送第二个回复，也不制造播放前缀。

第 5 次真实复测使用修补后的协议和真实协调器。新项增量先到，协调器在同一毫秒级观察到一次 `holdPlayback`，之后同项 `speech_started`、停止、提交、最终识别均到达。一次 `response.create`、一次 `response.cancel`、零次输出释放；压制时合成上行音轨为 live/enabled，播放器从开始静音。原回复返回 `completed`，而非 `cancelled`：这只能说明本次取消与原回复完成存在竞争，不能声称供应商已取消。最终投影有两条用户最终话轮、一个助手话轮，助手播放证据未知且无冻结前缀；本地关闭后远端释放为 `unconfirmed`。完整脱敏记录见[修补后证据](evidence/2026-11-11-qwen-controller-interruption-fixed.json)。返回 usage 841 Token。

两次有 usage 的调用合计 1,636 Token；按此前记录的北京价格估约 0.0038175 元，仅为已返回部分的估算，其余 3 次及实际账单未知。一次回复终态、本地关流或软预算都不能证明上游释放和硬停费。

## 验证和边界

新增回归先因 `qwen_protocol_unavailable` 失败，再通过；覆盖增量先于开始、精确重放、不同项、空/畸形增量、完成竞态及真实协调器配替身传输的正常/立即结束。Flutter 全量 1549 通过、10 项专用 skip；Node 83 通过；探针关联原有测试 11 项与新探针测试 2 项通过；Flutter analyze、5 文件格式、Ruff、Node 语法和 Web release 构建通过（不含 Wasm dry-run）。构建后已恢复 `lib/main.dart` 产品入口，产物传输脚本与源码 SHA-256 均为 `8df70fa9ac1c9dcfdbb0e6ee40e76fc0af6eb7cf3e9640129257964a7c1195ad`。

探针脚本为 `scripts/qwen_controller_interrupt_probe.py`、`scripts/qwen_controller_interrupt_page.js` 和 `apps/client/test/web/qwen_controller_probe_entry.dart`；运行前须按源码构建对应 Flutter target，服务器检查构建标记、绑定本机回环并限制一次交换；普通产品构建不可当实验入口。诊断时的原脚本保存在[身份核对脚本](evidence/2026-11-11-qwen-controller-interruption-identity.js)；最终实验页 SHA-256 为 `bc425b7b9e5f6795f165e72a4c8c7e6a3b8f8181faf7ed2d83f3742b8718fec2`。其余实测前脚本经历过添加事件诊断的调整，不能把当前脚本冒充这些实验的逐字副本。

这不是自然多轮聊天：音频一直静音、没有人耳或真机验证，输入只由合成语音提供，取消后输出不恢复，不发送下一次回复；尚未验证音频与文字前缀、旧音频安全清除、上下文重建、客户端消失后的可信远端退出或实际账单。正式协议工厂及后端准入保持关闭。下一步应在已获得事件顺序证据基础上验证安全恢复与可信退出；没有证据时不能自动放开旧音轨或当作已停费。
