# 千问实时语音准入资料复核

日期：2026-10-24（Asia/Shanghai）。这是公开官方资料及当前实现的复核，没有账号登录、供应商API或模型调用。继续沿用千问北京WebRTC候选；没有决定更换供应商、媒体路线或预算规则。

## 核查结论

2026-10-25本轮用户明确“先只查公开资料”。已补[官方SDK与控制接口复核](2026-10-25-qwen-control-contract-public-review.md)：固定3份SDK源码/测试与7份Omni相关页面，SDK发送finish/delete的方法不构成具体型号支持证据，Qwen-Audio删除确认和Responses会话管理不能套用Omni。RTC三接口补核TaskId、离线阈值和终态区别，仍缺重复/迟到创建与查无对象、精确播放上下文及费用等语义。没有SDK升级、供应商调用、方案切换或新适配；询问稿保留，不提交工单。以下历史“三网关Unavailable”等状态以最新复盘配置/交接为准，语音准入仍关闭。

2026-10-25继续[音频与worker实测](2026-10-25-qwen-audio-worker-verification.md)：合成英文PCM真实上传并得到一致ASR final及语音回复；取消后对实际assistant item发送一次OpenAI样式truncate，本次约29.127秒未收到确认/error。不是已证明所有千问型号都不支持，而是仍没有可用确认可接入客户端上下文门。真实ASR文字离线重放至真实复盘worker/用量存储及重启/删除已有证据，正常媒体准入保持关闭。需要供应商回答的精确契约已整理为[询问稿](2026-10-25-qwen-upstream-capability-questions.md)，没有发送或虚构回复。

2026-10-25后续[受控真实实验](2026-10-25-qwen-realtime-live-probe-verification.md)补齐北京Plus WebSocket真实连接、配置确认、文本输入到语音输出、一次生成取消与用量观测。本型号本次session.finish返回invalid_value；取消响应无usage；双方1000关闭帧与本机12秒清理没有证明远端资源/费用终态。此证据不属于WebRTC，也未验音频输入或设备播放；以下2026-10-24资料复核保持其历史适用范围。账号和20元实验预算已提供，不再重复索要；真实设备及可信退出/截断仍缺。

候选SDP适配不能据此开放正常语音准入。还缺覆盖Answer丢失、客户端消失的可信终止/失效依据，以及插话后精确播放前缀与上游上下文截断确认。未检索到依据只表示本次所查资料不足，不证明供应商绝无该能力。当前`create_app`三类网关及Flutter默认协议仍Unavailable，`termination_checks.py`只有blocked意图/只读端口，无上游执行器。

## 官方事实与冲突

| 项目 | 核查结果与适用边界 |
| --- | --- |
| WebRTC初始化 | [通用接入](https://help.aliyun.com/zh/model-studio/realtime-webrtc-access)要求处理客户端与服务端DataChannel，Omni等待session.created、发送session.update、收到session.updated后才挂载上行。现有传输层activate门与此一致；本轮本地合成回环通过，不是供应商配置实测 |
| 示例门控差异 | [最佳实践](https://help.aliyun.com/zh/model-studio/best-practice-webrtc-omni-realtime)示例在session.created便恢复媒体，再发送配置；与通用页有差异。工程建议保留配置确认后的更严格门，实际账号还需核验回显与拒绝路径 |
| 会话结束差异 | [Omni总览](https://help.aliyun.com/zh/model-studio/realtime)“结束会话”提到session.finish或关闭WebSocket，但[WebSocket概览](https://help.aliyun.com/zh/model-studio/realtime-websocket-overview)的模型差异表对Omni列的是关闭连接，finish/finished列于ASR/TTS等其他模型。本次Omni客户端/服务端事件表没有finish/finished定义，不借其他模型事件补造确认 |
| 取消与完成 | [客户端事件](https://help.aliyun.com/zh/model-studio/client-events)定义response.cancel用于取消当前响应；[服务端事件](https://help.aliyun.com/zh/model-studio/server-events)的response.done是响应生成及token用量快照。二者均不构成整个连接关闭、设备已播或费用结清证明 |
| 静默超时 | 客户端事件的idle_timeout_ms对适用型号用于静默后主动触发回复，不是连接TTL或可信过期边界，不能用它解锁unknown |
| 本地清理 | WebRTC通用页和最佳实践清理端侧采集、DataChannel、PeerConnection及播放器；所查资料未给覆盖Answer丢失的服务端查询/终止及最长回收承诺，不能把pc.close当可信上游结束 |
| 插话/上下文 | 本次Omni事件表未找到conversation.item.truncate、对应确认或按音频时刻对齐文本的契约；response.cancel/音频生成完成不能替代精确已播前缀。已有RealtimeProtocolCallbacks要求verified output position和confirmContextTruncated，继续不提供假确认 |

最佳实践包含MediaRecorder下载演示；本项目默认不保存原始音频，不能照搬录音逻辑。协议媒体上传也以WebRTC轨道为准，不复制WebSocket的Base64上传方式。

## 缺少退出能力时的路线候选

| 候选 | 已找到的资料 | 仍缺什么 |
| --- | --- | --- |
| 现有百炼WebRTC直连 | 当前固定北京workspace SDP路径；客户端关闭说明 | 服务端可定位的连接身份、Answer丢失后查询/撤销、可信回收上界、插话截断、实际费用来源 |
| 业务服务端持有WebSocket | 官方概览支持服务端接入；工程上可由后端控制媒体转发和连接关闭 | 这是工程候选，尚无本项目实现/延迟证据；后端崩溃后上游释放界限、弱网/回声处理、播放前缀与上下文仍需验证，不能自动满足准入 |
| 阿里云RTC智能体 | 官方[StartAgent](https://help.aliyun.com/zh/document_detail/2937117.html)允许业务指定TaskId，并列用户未加入/离开频道后的UserInactivityTimeout；[StopAgent](https://help.aliyun.com/zh/document_detail/2937122.html)接AppId/ChannelId/TaskId；[GetAgent](https://help.aliyun.com/zh/document_detail/2937118.html)列Status和StopTime | 是另一个产品接口，不可套到现有百炼SDP会话。需另核权限/模板/计费、创建幂等与丢回包、Stop受理后的终态查询、任务结束和费用边界、上下文及Flutter Web兼容；未选用、未接入、未调用 |

RTC的StopAgent返回RequestId，不单凭受理结果标已结束；GetAgent中“正在停止”与“已经结束”也须区分。该候选公开控制面更具体，但不是已验证可替代方案，也不代表费用硬上限。

## 真实接入前的执行顺序

1. 账号/workspace/地域/目标型号权限及允许预算齐备后，先核对供应商对断线回收、Answer丢失和按连接查询/终止的正式说明。输入继续按用户已有暂缓安排，不重复索取。
2. 为每次尝试在外调前保存可核对的稳定身份；若供应商不能提供身份或可信失效上界，不打开普通用户准入。不能因等待一段本地时间便解除unknown。
3. 最小受控实测先覆盖信令成功但回包丢失、收到Answer后页面消失、业务后端失联/崩溃、断网及恢复核验；逐项记录上游状态与实际用量，不用客户端时长或余额代替结算。
4. 再核配置确认与音频上行、自然插话的本地停声/上游取消/上下文截断三段证据。缺少精确播放对齐时不固化已播前缀；不能用response.done推断实际听到的文字。
5. 条件成立后选择适配器与正常准入工厂，接正式通话/结束页；复用现有journal、end/manifest/seal与历史/删除。真实文本反馈和人工语义抽查随后完成，再做B6。

这些步骤细化既有B2准入门，没有新增产品决定。当前不需要靠外围功能填充进度；浏览器工具已恢复后的新增证据见[页面/预览/回环实测](2026-10-24-browser-acceptance-verification.md)。
