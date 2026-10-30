# 客户端内存对话投影契约

日期：2026-10-18。本文记录已接到PracticeMediaController的内存投影契约；实际供应商协议仍Unavailable，没有正式练习页。2026-10-20已另增[最终文字追加/确认](2026-10-20-final-transcript-storage.md)，不改变本文的内存播放证据语义，不声明真实语音或完整学习闭环已实现。

2026-10-21已实现受限正常收尾、独立封存输出前缀及[原连接播放证据账本](2026-10-21-playback-evidence.md)，依据[收尾与中断前缀契约](2026-10-20-practice-completion-and-review-contract.md#3-自然插话后的文字与上下文)。已接受的播放、首次freeze和revoke可独立提交及只读重建，同日后续已接入[正常end的服务端输入固化](2026-10-21-practice-finalization.md)。当前上下文确认仍仅用于同一内存作用域；服务器sealed只固定已收事实和引用，recoverable仍false，不能宣称真实供应商插话或跨进程恢复。

## 作用域与输入

ConversationProjection只管理一个ConversationScope：accountId/sessionId/connectionId/clientInstanceId/epoch。运行时媒体控制器根据已登记连接创建；UUID规范为小写，epoch为严格正32位整数。适配器emitConversation(update, channelId)只提供归一化更新，不能修改作用域。控制器以原guard检查账号/前台/单调截止/租约，并要求传输可用且来自已确认配置的同一通道；音轨activate尚待完成时可接收该通道的文字。就绪前或其他通道上报导致本地安全停止。

| 输入 | 语义与检查 |
| --- | --- |
| TurnStartedUpdate | 语音开始/输入提交或AI response开始即登记稳定ID、索引和角色；revision=0、无文字，不是最终识别 |
| TranscriptUpdate | turnId/turnIndex/role/revision/text/isFinal，assistant另需responseId，可选providerItemId；索引/角色/响应/供应商映射一经建立不改变 |
| PlaybackUpdate | turnId/responseId/transcriptRevision/独立revision/status/playedText/playedUntilMs/source，绑定具体文字版本 |

适配器负责将供应商item/response和次序映射到稳定业务ID/索引。turnId/responseId为UUID，正revision和索引不超过2147483647，providerItemId若有则非空且最多256字符。允许索引缺口与文字乱序到达，投影按索引排序；不按收到的顺序伪造新话轮。TranscriptUpdate的text始终是完整当前文字，不能把重复delta再次拼接。

文字同revision同内容为duplicate，冲突抛固定conversation_invalid；旧版为stale，新final可修订，final不能退回临时。尚无首次final时，providerItemId允许从null单向绑定一次，跨话轮重复item和改绑拒绝；首次final之后映射固定。空白/空final可保留无可用文字事实，不进入上下文。最终文字仍是客户端报告，不代表识别准确或自动满足反馈引用资格。

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

snapshot/turns/context均为不可变值；context保留原scope、角色、turnId/索引/文字revision/responseId和固定client_reported来源。选择用户非空final、assistant final的可靠partial/played前缀，或独立封存的interruptedPrefix；后者保存原文字/播放revision、输出位置、停止上限、来源和原因，不将整轮interim升级为final，也不进入最终文字journal。hasUnfinalizedText和hasUnconfirmedPlayback是分别可见的缺口，isSealed仅说明本地不再接收，均不是持久转写完整的证明。

每连接最多256轮；单条生成文字/播放前缀各8192 UTF-8字节，内部当前正文、播放及独立封存前缀合计最多262144字节。拒绝无效Unicode，不逐出已接受文字；容量错误conversation_limit_reached在任何修改前拒绝。只保留每轮最新版本及至多一份可靠封存前缀，不保留无界事件列表、音频、浏览器缓存或完整原始供应商事件。外部旧不可变快照不计入当前投影预算，消费者应随账号作用域销毁并禁止跨账号缓存。

当前stop同步seal后再释放协议/媒体，保留已接受内容；迟到回调不能恢复文字。账号变化、dispose清空并封存；conversation getter身份不符返回null并清空内部文字。投影冲突/容量失败同步本地停止并保留已接受快照，不将原话或供应商标识写入错误/受限观测journal。

freezeResponse首次固定response停止上限及原因，相同重放不顺延，变更上限拒绝；后续播放不得超出停止上限，新文字revision不继承旧播放。旧版已封存前缀可独立保留，明确推翻对齐的事实用revokeFrozenPrefix撤销并禁止重用该response播放证据。正常结束在固定窗口内接收原final后seal；自然插话仅冻结旧response事实，用户输入保持接收。新回复用已确认的不可变上下文token，原窗口内晚final仍可保存而不改该token；撤销已用依据会安全停止。截止和通道由媒体协调器执行。

媒体控制器仅将applied PlaybackUpdate后的完整turn交给独立播放journal，首次freeze采集停止前原turn，revoke先入队再处理已用上下文失效。新final不将旧前缀改绑至新版本；原来源可由自含事件持久保留，不依赖最终文字队列的确认顺序。播放账本和内存投影分别受限，不扩大本投影的正文预算。

本内存投影不承担持久固化或反馈任务。正常end在本地seal前保存快照，包含全部!isFinal turn及未知输出缺口，再由两journal无正文清单与独立completion client提交；不能只用hasUnfinalizedText，因为它不包含空文字TurnStarted。服务器固化另外派生候选话轮资格及同版本final_prefix/原freeze的interrupted_prefix引用，候选策略尚未覆盖全部质量/上下文规则，不修改本地已确认context token，也不自动恢复供应商上下文。

文字/播放ACK、本地isSealed及服务器sealed分别表达接收、本地停止和固定输入，均不能替代可信终止、完整反馈资格、真实自然打断或上游截断。原投影验证与替身范围见[验证记录](../development/2026-10-18-conversation-projection-verification.md)，前批持久证据见[播放记录](../development/2026-10-21-playback-evidence-verification.md)，本批最终实测见[固化验证报告](../development/2026-10-21-practice-finalization-verification.md)。
