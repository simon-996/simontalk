# 最终文字追加与确认契约

本批实现客户端申报的最终转写修订存储。对应[设计](../superpowers/specs/2026-10-20-final-transcript-storage-design.md)及[内存投影](2026-10-18-conversation-projection.md)。默认准入、供应商网关、归一化协议继续关闭，无正式练习/历史界面；成功来源为测试中的归一化输入，不代表实际语音验证。

## 服务端

`POST/GET /v1/practice-sessions/{sid}/connections/{cid}/transcripts`，本人鉴权，Web 写入需 Origin、CSRF、X-Account-ID；所有提供了 X-Account-ID 的读写均核对身份。追加锁序 User→Practice→Connection，等待账号锁后重新查撤销/禁用。

请求含 `client_instance_id`、`epoch` 和1–4个 events。事件字段：event_id、sequence、turn_id、turn_index、role、revision、text、response_id、provider_item_id。UUID 规范化；sequence/index/revision 为正32位整数，拒绝布尔/字符串。text 必须合法UTF-8、不含NUL、0–8192字节；provider_item_id 可空，否则1–256个Unicode字符、不含NUL/无效Unicode。assistant 必须带response UUID，user 不得带。无 is_final 字段，因为此端点只接收最终修订；任何播放/来源/额外字段拒绝。

事件 ID、sequence 只在原连接内唯一，同turn的revision唯一。相同event_id全部规范字段一致则精确重放，不新增/改写received_at；同ID不同内容409 transcript_conflict。新sequence须高于当前最大值，低水位409 transcript_sequence_stale；新turn修订须高于该turn已接收revision，旧/同revision新event409 transcript_revision_stale。turn_id首次确定的index/role/response/provider映射不可改变，不同turn不能共用index。允许索引/版本/sequence缺口，不以到达顺序作为对话顺序。整批核验通过才提交，不部分接受。

每连接最多512个修订、256turn、累计text 1MiB，触限429 transcript_limit_reached；精确重放不占额外预算。请求256KiB/总接收5秒，通过实际分块计数而非Content-Length。错误只返回固定码/说明/request ID，正文不进错误输出。数据表final_transcripts复合外键绑定connection_id/client_instance_id/epoch，账号和练习从原连接归属继承；父连接/练习/账号删除级联，不通过upsert重建父记录。数据库额外检查正数、角色/response、UTF-8字节数、来源、摘要等单行约束。

ACK：source=client_reported、account_id、session_id、connection_id、client_instance_id、epoch、last_sequence、total_events、total_text_bytes、acknowledged_event_ids（请求原顺序）。它证明这些申报已接收，不证明内容识别正确、已经播放、会话已经固化或供应商终止。

GET：after_sequence=0..2147483647，limit=1..32；返回同身份/统计、events（含服务器received_at和delivery_status）、next_after_sequence、has_more。每次读取同一SQL结果中的事件与水位，跨页不是冻结快照。旧turn的新修订拥有新sequence，可在已翻过该turn后继续读取。按turn_id最大revision得当前文字，再按turn_index排序；AI的delivery_status永远unknown，user为null，不能拿所有AI生成文本恢复“已交流上下文”。

历史或unknown连接可以补交原连接文字，既不续租、不释放占用，也不更改练习/连接状态或终止。preparing/not_started上的文字也只是客户端申报，不能证明上游已开始，不改变明确准备清理的完整历史判定。尚无finalize/seal/delete HTTP，不能把本地stop当服务端固化。

## 客户端

FinalTranscriptJournal 接收最终 TranscriptUpdate，使用有界投影校验映射和修订；临时字幕/播放更新不入队。稳定UUID事件与递增sequence在入队时生成一次。每批最多4条，账号ApiClient fork独立HTTP所有权，8秒总截止包含CSRF；精确核对全部ACK身份、IDs、统计后移除。失败暂停，不自动重试；显式retryPending保留原ID/内容，服务器已提交但响应丢失仍可重放消歧。

pending至多64条、文字256KiB；整个实例512个修订/1MiB/256turn。拒绝记录计数与安全错误码可读，不能静默丢弃后显示全部保存。finish停止接收，继续已排队内容；abort同步清空、取消请求并清除校验中的文字。账号变化/销毁abort，晚确认不会恢复数据。Web仅内存，刷新后未确认内容可能丢失，移动受保护outbox尚未实现。

PracticeMediaController在配置确认通道、账号/前台/租约保护后应用投影，仅applied的最终TranscriptUpdate提交；重复/过期/播放/临时更新不提交。停止封存并finish，销毁/身份变化abort。Riverpod默认装配受账号控制，但读取provider不会启动练习、申请媒体或POST。未接正式练习UI，队列错误/pending/rejected统计由控制器提供供后续界面接入。
