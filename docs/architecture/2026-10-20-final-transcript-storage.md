# 最终文字追加与确认契约

本批实现客户端申报的最终转写修订存储。对应[设计](../superpowers/specs/2026-10-20-final-transcript-storage-design.md)及[内存投影](2026-10-18-conversation-projection.md)。默认准入、供应商网关、归一化协议继续关闭，无正式练习/历史界面；成功来源为测试中的归一化输入，不代表实际语音验证。

2026-10-20补齐的[收尾与反馈依据契约](2026-10-20-practice-completion-and-review-contract.md)定义draining、最终提交窗口和资格派生。2026-10-21已有客户端受限draining及[独立播放证据账本](2026-10-21-playback-evidence.md)，本批接入[正常结束、固定补交与服务端固化](2026-10-21-practice-finalization.md)。本接口最终文字语义未变，保持与播放账本的双向核验，并共同执行补交/清单/seal门。独立已播前缀不进入此API，AI播放状态仍unknown；本批最终实测另见[验证报告](../development/2026-10-21-practice-finalization-verification.md)。

## 服务端

`POST/GET /v1/practice-sessions/{sid}/connections/{cid}/transcripts`，本人鉴权，Web 写入需 Origin、CSRF、X-Account-ID；所有提供了 X-Account-ID 的读写均核对身份。追加锁序 User→Practice→Connection，等待账号锁后重新查撤销/禁用。

请求含 `client_instance_id`、`epoch` 和1–4个 events。事件字段：event_id、sequence、turn_id、turn_index、role、revision、text、response_id、provider_item_id。UUID 规范化；sequence/index/revision 为正32位整数，拒绝布尔/字符串。text 必须合法UTF-8、不含NUL、0–8192字节；provider_item_id 可空，否则1–256个Unicode字符、不含NUL/无效Unicode。assistant 必须带response UUID，user 不得带。无 is_final 字段，因为此端点只接收最终修订；任何播放/来源/额外字段拒绝。

事件 ID、sequence 只在原连接内唯一，同turn的revision唯一。相同event_id全部规范字段一致则精确重放，不新增/改写received_at；同ID不同内容409 transcript_conflict。新sequence须高于当前最大值，低水位409 transcript_sequence_stale；新turn修订须高于该turn已接收revision，旧/同revision新event409 transcript_revision_stale。turn_id首次确定的index/role/response/provider映射不可改变，不同turn不能共用index。允许索引/版本/sequence缺口，不以到达顺序作为对话顺序。整批核验通过才提交，不部分接受。

两个追加接口共享原连接锁，双向核对turn/index/role/response及同revision的正文/final位；来源或final单调性冲突返回409 playback_conflict，不能把用户原话登记为AI播放。较早interim来源可以从独立播放队列迟到，不因此覆盖本账本较新的final；两个账本的ID、sequence和容量分别计算。

每连接最多512个修订、256turn、累计text 1MiB，触限429 transcript_limit_reached；精确重放不占额外预算。请求256KiB/总接收5秒，通过实际分块计数而非Content-Length。错误只返回固定码/说明/request ID，正文不进错误输出。数据表final_transcripts复合外键绑定connection_id/client_instance_id/epoch，账号和练习从原连接归属继承；父连接/练习/账号删除级联，不通过upsert重建父记录。数据库额外检查正数、角色/response、UTF-8字节数、来源、摘要等单行约束。

ACK：source=client_reported、account_id、session_id、connection_id、client_instance_id、epoch、last_sequence、total_events、total_text_bytes、acknowledged_event_ids（请求原顺序）。它证明这些申报已接收，不证明内容识别正确、已经播放、会话已经固化或供应商终止。

GET：after_sequence=0..2147483647，limit=1..32；返回同身份/统计、events（含服务器received_at和delivery_status）、next_after_sequence、has_more。每次读取同一SQL结果中的事件与水位，跨页不是冻结快照。旧turn的新修订拥有新sequence，可在已翻过该turn后继续读取。按turn_id最大revision得当前文字，再按turn_index排序；AI的delivery_status永远unknown，user为null，不能拿所有AI生成文本恢复“已交流上下文”。

历史或unknown连接可在允许窗口补交原scope文字，不续租、不释放占用，也不证明终止。preparing/not_started上的文字同样只是客户端申报，不能证明上游已开始，不改变明确准备清理的完整历史判定。本批end/manifest及追加完成可尝试固化输入，父练习因此ending/completed仍与连接占用分开；未发正常end的异常stop继续中断，不能把本地seal当服务端固化。未新增删除HTTP。

两个账本已同批增加固定门：正常end首次受理后30秒截止不顺延；新事件在锁后到期或sealed为409 practice_input_sealed。manifest已固定时，只允许其中声明且ID/sequence相符的未收事件，其他新事件为409 completion_manifest_conflict；精确已存事件仍可在截止或seal后重放确认，混合批次整体失败。不存在或不可访问的父对象先拒绝，终止核验保留的标识不赋予补交权。清单核对实际集合及bytes后可提前固化，未齐由maintenance到期收敛；固化版本/hash通过completion查询，本GET字段保持不变。候选话轮资格尚不等于完整反馈资格，播放/前缀事实仍独立保存。

## 客户端

FinalTranscriptJournal 接收最终 TranscriptUpdate，使用有界投影校验映射和修订；临时字幕/播放更新不入队。稳定UUID事件与递增sequence在入队时生成一次。每批最多4条，账号ApiClient fork独立HTTP所有权，8秒总截止包含CSRF；精确核对全部ACK身份、IDs、统计后移除。失败暂停，不自动重试；显式retryPending保留原ID/内容，服务器已提交但响应丢失仍可重放消歧。

pending至多64条、文字256KiB；整个实例512个修订/1MiB/256turn。拒绝记录计数与安全错误码可读，不能静默丢弃后显示全部保存。成功入队另保留无正文(sequence,event_id)及累计预算，ACK/finish不清metadata，供正常end固定全部事件清单。finish停止接收并继续已排队内容；abort同步清空metadata和正文、取消请求。账号变化/销毁abort，晚确认不会恢复数据。Web仅内存，刷新后未确认内容可能丢失，移动受保护outbox尚未实现。

PracticeMediaController在配置确认通道、账号/前台/租约保护后应用投影，仅applied的最终TranscriptUpdate提交；重复/过期/播放/临时更新不提交。停止封存并finish，销毁/身份变化abort。Riverpod默认装配受账号控制，但读取provider不会启动练习、申请媒体或POST。未接正式练习UI，队列错误/pending/rejected统计由控制器提供供后续界面接入。

正常end的账号作用域同时保留两队列及结束/清单/封存凭据操作，任一pending或completion待收敛都保留。服务端sealed后，由校验原scope及全局hash的receipt确认实际refs；缺失pending计permanentlyUnsavedCount并暴露sealed_unsaved，停止重试、取消在途并忽略晚ACK、清正文，不当作已确认或普通拒收。全部确认或明确缺失收敛后，允许无页面监听的作用域释放；metadata保留到abort。最终文字只读UI仍将AI播放显示为unknown，输入固化也不自动生成恢复上下文，正式保存状态页尚缺。
