# 客户端内存对话投影契约

日期：2026-10-18。已接到PracticeMediaController的归一化协议回调；实际供应商协议仍Unavailable，没有正式练习页、转写HTTP或持久文字。本批不声明实时语音或完整学习闭环已实现。

## 作用域与输入

ConversationProjection只管理一个ConversationScope：accountId/sessionId/connectionId/clientInstanceId/epoch。运行时媒体控制器根据已登记连接创建；UUID规范为小写，epoch为严格正32位整数。适配器emitConversation(update, channelId)只提供归一化更新，不能修改作用域。控制器以原guard检查账号/前台/单调截止/租约，并要求传输可用且来自已确认配置的同一通道；音轨activate尚待完成时可接收该通道的文字。就绪前或其他通道上报导致本地安全停止。

| 输入 | 语义与检查 |
| --- | --- |
| TranscriptUpdate | turnId/turnIndex/role/revision/text/isFinal，assistant另需responseId，可选providerItemId；索引/角色/响应/供应商映射一经建立不改变 |
| PlaybackUpdate | turnId/responseId/transcriptRevision/独立revision/status/playedText/playedUntilMs/source，绑定具体文字版本 |

适配器负责将供应商item/response和次序映射到稳定业务ID/索引。turnId/responseId为UUID，正revision和索引不超过2147483647，providerItemId若有则非空且最多256字符。允许索引缺口与文字乱序到达，投影按索引排序；不按收到的顺序伪造新话轮。TranscriptUpdate的text始终是完整当前文字，不能把重复delta再次拼接。

文字同revision同内容为duplicate，冲突抛固定conversation_invalid；旧版为stale，新final可修订，final不能退回临时。空白/空final可保留无可用文字事实，不进入上下文。最终文字仍是客户端报告，不代表识别准确或自动满足反馈引用资格。

## 生成与输出证据

每个assistant同时保存生成text和独立ConversationPlayback，初始unknown。生成final、transport playback_playing、音轨激活、SDP或协议配置确认均不能自动产生已播放文本。

| 交付状态 | 接受条件 |
| --- | --- |
| unknown | source=unknown，playedText为空、位置null；没有可采信的播放证据 |
| notPlayed | 生成已final，source=deviceOutputAligned，前缀为空、位置0；确认没有输出的交付终态，不是暂时等待 |
| partial | source=deviceOutputAligned，非空严格生成前缀、正毫秒位置 |
| played | 生成已final，source=deviceOutputAligned，非空全文完全相同、正毫秒位置 |

位置最多86400000毫秒，只保存明确上报的事实。deviceOutputAligned要求适配器已经验证设备输出与文本对齐依据；枚举本身不会验证硬件，不能从时长或字符比例估算前缀。没有这样的能力就维持unknown，不伪造精确播放文字。证据为client_reported，不证明人已听到/理解、可信服务端终止或结算。

当前文字版本的播放同revision一致重放，否则冲突；旧播放revision忽略。已知前缀与位置不得回退，unknown不能抹去已知事实，played/notPlayed终态不得改变。新文字revision会重置原播放证据，哪怕新文字恰好相同也需重新对齐。指向旧文字版本为stale，尚无文字或指向未来版本为awaitingTranscript；不缓存此类证据，不推进投影版本，适配器在对应文字到达后可明确重发。

## 输出、限制与生命周期

snapshot/turns/context均为不可变值；context保留原scope、角色、turnId/索引/文字revision/responseId和固定client_reported来源。仅选择用户非空final、assistant非空final且有partial/played证据的前缀；临时文字、未知后缀和确认未播放文字均不补入。hasUnfinalizedText和hasUnconfirmedPlayback是分别可见的缺口，isSealed仅说明本地不再接收，均不是持久转写已完整的证明。

每连接最多256轮；单条生成文字/播放前缀各8192 UTF-8字节，内部当前正文和播放前缀合计最多262144字节。拒绝无效Unicode，不逐出已接受文字；容量错误conversation_limit_reached在任何修改前拒绝。只保留每轮最新版本，不保留无界事件列表、音频、浏览器缓存或完整原始供应商事件。外部保留的旧不可变快照不计入当前投影预算，消费者应随账号作用域销毁并禁止跨账号缓存。

正常stop同步seal后再释放协议/媒体，保留已接受内容供未来正式结束流程使用；迟到回调不能恢复文字。账号变化、dispose清空并封存；conversation getter身份不符返回null并清空内部文字。投影冲突/容量失败同步本地停止并保留已接受快照，不将原话或供应商标识写入错误/受限观测journal。

本批没有完整领域事件信封/持久水位、最终提交、反馈任务、跨进程恢复、自然打断及上游上下文截断。已封存的本地快照不能直接当作服务器历史或恢复凭证。验证与替身范围见[验证记录](../development/2026-10-18-conversation-projection-verification.md)。
