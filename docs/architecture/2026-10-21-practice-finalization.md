# 正常结束、固定补交窗口与输入固化契约

日期：2026-10-21。已实现原连接结束受理、不可变提交清单、双账本补交门、持久输入固化、原账号客户端接入及封存接收凭据。本文按当前代码记录实际接口；迁移、真实HTTP、全量检查与复核结论统一见[本批验证报告](../development/2026-10-21-practice-finalization-verification.md)。依据[集中收尾契约](2026-10-20-practice-completion-and-review-contract.md)及[本批设计](../superpowers/specs/2026-10-21-practice-finalization-design.md)。

正常`end`才发起本单元产品结束。未发正常end的后台、断线、离页和异常stop仍沿用中断及安全准备清理语义，不自动转换为正常结束。默认供应商准入、网关及客户端协议继续关闭；没有正式练习/结束保存页面、真实供应商收尾信号或可执行终止核验器。

## 1. 状态、范围与身份

| 事实 | 当前含义 |
| --- | --- |
| 本地draining/localClosed | 麦克风与本地声音停止、原窗口内事实接收结束；不证明服务端已保存或上游终止 |
| PracticeCompletion ending | 服务端已登记结束意图、固定成员范围和补交截止；PracticeSession为ending |
| PracticeCompletion sealed | 输入版本1及每条连接snapshot/hash已固化；PracticeSession为completed、state_reason为input_sealed |
| coverage complete/incomplete | 声明与实收核对及已知缺口结果；输入可不完整地固化，不证明原音识别准确 |
| 连接unknown与blocked核验意图 | 原连接仍占用；保存或固化不能使termination_status变confirmed |

结束冻结同一练习已有的全部连接，成员身份包含connection_id、client_instance_id和epoch。首次end须作用于当前connection/epoch；历史成员可用自己的原scope提交清单，但不得借结束请求影响后来连接。锁序沿用User→Practice→按epoch/id排序的Connection，写入等待账号锁后重新核验登录撤销和账号禁用。

所有接口要求本人鉴权，提供X-Account-ID时核对当前身份。Web写入还需Origin与CSRF。UUID规范化；输入拒绝额外字段、布尔整型和超量数据；错误不回显正文或凭证。真正删除父账号/练习/连接时由外键级联清理本批关联记录，当前未新增删除HTTP。

## 2. 两阶段写入与摘要

以下路径均以`/v1/practice-sessions/{sid}`为前缀。

| 方法与路径 | 输入/结果 |
| --- | --- |
| POST /connections/{cid}/end | Idempotency-Key为UUID；body为client_instance_id、epoch。成功200统一摘要 |
| POST /connections/{cid}/completion-manifest | 原scope与下述固定清单，无第二个幂等key；成功200统一摘要 |
| GET /completion | 200统一摘要；未登记为404 completion_not_found。纯读，不触发固化、续租、建连或上游请求 |
| GET /connections/{cid}/completion | 该成员的覆盖明细；未固化为临时视图，已固化为不可变snapshot；始终recoverable=false |
| GET /connections/{cid}/completion-receipt | 仅已固化时200返回实际接收事件身份；未固化为409 completion_not_sealed |

首次end在一个事务内写入唯一PracticeCompletion、固定成员范围及`accepted_at`，`final_upload_deadline=accepted_at+30秒`。同key、同原连接和相同规范body重放返回原记录的当前摘要；另key或同key异内容为409 idempotency_conflict，不延长截止。已取消/失败/完成的练习不能首次登记，当前连接/epoch变化分别返回明确冲突。

manifest body固定为：`client_instance_id, epoch, transcripts, playback, tail_status, unfinalized_turn_ids, unconfirmed_response_ids, transcript_rejected_count, playback_rejected_count, journal_unavailable`。两个ledger各含`events:[{sequence,event_id}], last_sequence, total_events, total_text_bytes, pending_count_at_close`，不含第二份正文。

refs须按sequence严格递增，序号及ID唯一；last为最大序号、total为列表长度，空清单水位和bytes为0。文字最多512项/1MiB，播放最多768项/2MiB；pending在0..total范围内。sequence允许不连续。清单包括已ACK及pending的全部接纳事件，pending_count_at_close只是固定历史快照，不等于服务端实际未收。tail_status为complete/unconfirmed/aborted；两种ID列表各最多256个且唯一，拒收数为非负32位整数，journal_unavailable为bool。当前controller没有可信收尾完成回调，不申报complete。

每成员只接纳一份规范清单；相同清单精确重放可确认，变更为409 completion_manifest_conflict。首次清单在锁后已到截止或已sealed时为409 practice_input_sealed；客户端改为读取固化结果，不无限重发已不可能接纳的清单。end实际分块接收上限8KiB，manifest为256KiB，接收总时限均为5秒。

统一摘要字段为：`source=server_recorded, account_id, session_id, origin_connection_id, client_instance_id, epoch, end_key, status, accepted_at, final_upload_deadline, sealed_at, input_revision, input_hash, coverage, connection_count, gap_codes`。

ending时revision=0、sealed_at/hash为null、coverage=pending；sealed时revision=1、sealed_at非空、hash为小写SHA256、coverage为complete或incomplete。摘要身份始终属于最初end的origin，历史成员提交成功返回的也是该origin摘要。客户端仓库用独立expectedOriginScope严格校验返回身份，POST路径和body仍使用历史成员自己的scope。

## 3. 双账本覆盖与持久固化

[最终文字](2026-10-20-final-transcript-storage.md)及[独立播放证据](2026-10-21-playback-evidence.md)追加共同执行以下门；来源、版本、容量和整批原子规则继续有效。

1. 先核对父对象、所有权和原连接身份。已存event的全部规范内容精确一致，可在截止及seal后重放确认，不改received_at、snapshot、hash或固化时间。
2. 新事件在`now >= final_upload_deadline`或sealed时为409 practice_input_sealed；混合批次整体失败。后台调度晚于截止不放宽写入窗口。
3. 清单已到时，只允许其中声明且ID/sequence相符的未收事件补交；新未声明ID或错sequence为409 completion_manifest_conflict。清单没有将临时字幕升级为final，也没有将AI生成文字升级为播放事实。

end、manifest和两账本追加可尝试提前固化：每成员都须有清单，且实际ID/sequence/count/bytes与声明相符。仅首次end前已安全终结、epoch小于origin、完整历史证明从未调用上游且两账本为空的历史成员可记empty_not_started；origin即使刚被end安全关闭仍必须等待manifest，不能把其他未申报连接视为完整。明确tail、拒收或播放缺口不阻止固定实际输入，但coverage为incomplete。

未齐的ending由已有maintenance循环或维护批次在截止后扫描，限量、skip_locked并按锁序重查；重启后依据数据库ending继续处理。PracticeCompletion和CompletionConnection保留唯一范围、固定清单、snapshot及hash，不依赖内存Future或通用任务队列。GET始终纯读，后台尚未扫描时可以暂时仍显示ending。

每成员固化明细包含原scope、sealed/input_revision/input_hash、coverage/gap_codes、manifest_received/tail_status、两ledger的declared和received统计、missing_event_ids/unexpected_event_ids/events，以及turns引用。missing/unexpected按实际ID与sequence映射计算，不能只凭sequence、turn index或revision跳号推断丢失。全局gap_codes为成员缺口去重排序：

`manifest_missing, transcript_missing, playback_missing, transcript_unexpected, playback_unexpected, manifest_totals_mismatch, transcript_rejected, playback_rejected, unfinalized_turn, unconfirmed_response, journal_unavailable, tail_unconfirmed, tail_aborted, playback_revoked, playback_unconfirmed`。

成员hash覆盖schema/policy、原scope、固定manifest、排序事件ID及既有event_digest、覆盖/缺口与turn引用；全局hash覆盖按epoch/id排序的成员身份及成员hash，不包含会继续变化的终止状态。输入版本固定为1，无补录再评价、自动生成反馈或重新付费调用。

## 4. 候选话轮及输出引用

当前policy为`final_text_candidate_v1`。turn取最终文字账本中该turn最大revision，空修订覆盖旧原话，引用包含turn_id/turn_index/role/transcript_event_id/revision。保存的是候选资格：非空用户final为eligible/user_final_text；被清单明确标为未final的用户turn为uncertain/unfinalized_turn；空final为excluded/empty_text；AI为excluded/assistant_text。尚无完整质量证据/关键上下文规则或正式反馈资格验证，不能将候选eligible解释为已证明识别准确，也不会因为缺confidence排除全部正常用户文字。

AI的final_prefix仅引用与最新final同文字revision、正文及final位相符的partial/played证据。首次freeze中的可靠、非撤销前缀另作interrupted_prefix，可保留原interim来源版本；不能迁移到新final。引用保存playback_event_id、文字/播放revision及delivery_status，正文继续由原账本保存。没有匹配最终文字的独立播放turn仍保存来源版本与相应缺口，不冒充用户final；revoke排除该response的两类前缀。所有引用保持client_reported事实属性，不自动重建供应商上下文。

## 5. 客户端与封存接收凭据

两个生产journal实现独立SubmissionManifestProvider：成功入队才保留(sequence,event_id)和累计预算，ACK/finish后继续保留无正文metadata，abort/身份变化清空。正文只由原有有界投影/队列持有；没有Web持久outbox或录音。

PracticeCompletionClient在原scope建立时构造，无HTTP或媒体副作用。正常end安排异步结束意图后立即同步停采停播，保持原3秒/租约更早的单调截止；即使drain抛错仍保留意图。关闭前采集所有未final turn（含无字幕输入）、未知输出response及journal缺口，finish两队列后固定manifest一次，允许它先于end ACK排队；先end后manifest串行，ACK不得重写清单。

HTTP使用原账号独立fork，每次8秒总截止包含CSRF，失败暂停显式重试。重复end复用key，清单重试复用body；只读refresh不隐式重试失败写入。清单已接纳或因seal不再可接纳后，只读轮询每2秒一次、每轮至多20次/40秒，延迟Timer也复核单调预算。到限保留completion_pending并等待明确重试，不延长服务器截止或本地媒体。

summary sealed还不足以处理丢ACK或到期缺失的pending。receipt字段为`source=server_recorded, account_id, session_id, connection_id, client_instance_id, epoch, sealed=true, recoverable=false, input_revision=1, input_hash, practice_input_hash, transcript_events, playback_events`。两事件列表只含服务端实际固化的(sequence,event_id)；input_hash属于该scope，practice_input_hash须匹配全局摘要。客户端严格验证身份及hash后才进入sealed终态。

控制器将receipt交给两journal的SealedSubmissionReconciler：仅实际refs确认接收，其他pending记permanentlyUnsavedCount并暴露sealed_unsaved；停止重试、取消在途请求并忽略晚ACK、清正文，不把缺失算作ACK或普通拒收。metadata保留到abort。provider在正常drain、任一正文pending、结束/清单/receipt待确认及失败待重试时留存原账号作用域，完成收敛后允许无监听释放。账号变化或销毁立即abort，不能借新身份补交。正常end后的同账号离页保留操作；未发end的普通离页仍只中断。

## 6. 终止意图与剩余边界

首次end中，有完整not_started且无offer/信令开始或完成证据的未终结连接可安全closed，原因ended_before_signalling；其他已尝试连接保持/进入unknown。end、信令失败、租约失效首次变unknown时，按原connection/attempt登记唯一TerminationCheck；maintenance有界补齐历史缺失任务。正常negotiating的unknown本身不提前触发终止。

当前核验记录固定`status=blocked, reason=capability_unavailable, attempts=0`，没有外部调用或执行器。它只记录待核验意图，不证明终止成功、费用封顶或占用解除。ending/completed父状态受到连接过期及信令晚到保护，结束后拒绝续租、新offer及新连接；completed+unknown仍可只读恢复并继续阻挡新建。

真实供应商输入完成/取消/对齐/截断、丢失信令答案与客户端消失后的可信退出、正式练习/保存/历史页面、完整评价资格、反馈任务/引用验证、一级重练/删除、用量结算与金额硬上限仍待后续。本文新增接口与客户端接入，不代表真实语音或学习闭环已经验收。


## 7. 恢复入口的保存与核验读取

2026-10-21新增原连接 `GET /v1/practice-sessions/{sid}/connections/{cid}/termination-check`，本人鉴权、X-Account-ID及no-store；单SQL将原连接与同client/epoch核验任务left join。返回严格 `source=server_recorded, account_id, session_id, connection_id, client_instance_id, epoch, status, reason, attempts, created_at`。无任务为not_requested/null/0/null；已有任务仅blocked/capability_unavailable/0/带时区登记时间。不返回attempt_digest，不创建核验任务、续租、解除占用或调用供应商；不存在/他账号连接404。

偏好页现有恢复面板已增加明确点击的保存状态查询：global completion与原连接termination-check一起核对成功才发布；历史占用连接与全局origin可能不同，客户端额外GET实际origin核对scope，原completion严格解析不放松。一个八秒总截止包含必要的三次GET，每次追加请求前复核单调时间及身份。准确completion_not_found仅表示未登记，其余错误不伪造保存结果。局部刷新先清旧展示，身份、父404、总刷新和销毁清全部；已核验登记end的无正文门在局部失败后继续禁用过期准备清理。

界面分别显示ending、sealed完整/缺口和连接/用量待核对。ending展示固定接收截止并等待封存，封存缺口不能通过刷新补回；只有真实blocked才提示需维护者确认。查询无end/manifest/上传/媒体副作用，不提供强制解锁或无限保存重试。本入口受current范围限制，安全终结后current为空时尚无完整历史入口。设计与证据见[保存状态设计](../superpowers/specs/2026-10-21-saved-status-recovery-design.md)和[实测报告](../development/2026-10-21-saved-status-recovery-verification.md)。
