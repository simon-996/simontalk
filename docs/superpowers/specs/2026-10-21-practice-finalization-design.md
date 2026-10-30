# 服务端结束受理、固定补交与输入固化

日期：2026-10-21。依据用户持续开发授权及[收尾契约](../../architecture/2026-10-20-practice-completion-and-review-contract.md)。本单元实现正常end的服务端闭环，不调用供应商、不新增正式练习占位页；真实准入/网关/协议继续关闭，原生暂停。

## 选择与边界

采用两阶段：立即end登记意图及固定30秒补交截止，媒体drain结束后提交不可变manifest。相比“等上传全部成功才结束”，它能在客户端消失后有明确截止；相比“只存最大sequence”，完整事件ID/sequence清单能核对实际收到的集合，允许合法序号缺口。沿用现有maintenance进程处理持久collecting状态，无需通用任务框架。

结束、文字保存、可信媒体终止和占用解除分开。completed只表示服务器输入已固化；unknown连接继续占用并可只读恢复。现阶段没有可信供应商完成回调，客户端正常到期仍申报tail_unconfirmed；无可执行终止核验器时仅持久登记blocked/capability_unavailable，不假造成功。

## 结束与清单wire

所有路径以`/v1/practice-sessions/{sid}`为前缀，JSON严格拒绝额外字段、布尔整型、无效UUID/Unicode；鉴权、Origin/CSRF/X-Account-ID沿用账号契约。锁序User→Practice→按epoch/id排序的Connection，等待锁后重验账号。

- `POST /connections/{cid}/end`：Idempotency-Key UUID；body `{client_instance_id,epoch}`。首次必须是练习当前连接/epoch，练习不可已取消/失败。同事务创建唯一PracticeCompletion、固定成员范围与`accepted_at`/`final_upload_deadline=accepted_at+30s`，父状态ending；同key同内容重放返回原状态，不延期，同key异内容或另一key冲突。历史scope不能借end影响后来连接。无连接准备仍用原有取消/清理。
- `POST /connections/{cid}/completion-manifest`：body `{client_instance_id,epoch,transcripts,playback,tail_status,unfinalized_turn_ids,unconfirmed_response_ids,transcript_rejected_count,playback_rejected_count,journal_unavailable}`。每原连接只接一份，规范内容精确重放允许，无需第二个key；不同内容409。连接必须在首次end冻结成员范围内。锁后now>=deadline或已sealed的新清单统一409 practice_input_sealed；仅已有清单的精确重放仍可确认，防调度延迟改变固化输入。
- 两个ledger manifest均为 `{events:[{sequence,event_id}],last_sequence,total_events,total_text_bytes,pending_count_at_close}`。refs严格递增、ID/序号唯一，last=max、total=列表长度、empty水位/bytes为0。文字512条/1MiB，播放768条/2MiB；pending为0..total；清单不含正文。tail_status为complete/unconfirmed/aborted；complete只是客户端收尾报告，当前controller从不使用它。未final turn与未确认response各最多256、UUID唯一；拒收数非负32位整数；journal_unavailable为bool。
- end body实际分块8KiB/5秒，manifest实际分块256KiB/5秒。错误不回显正文或凭证。
- 清单包含ACK过及pending的全部接纳事件。pending_count_at_close是固定历史快照，不当作实际未收证明；后续ACK不改清单，拒收不制造phantom refs。清单到达后，只允许其中声明、尚未到达的事件补交；新未声明ID或错sequence拒绝。既有记录精确重放不受此门影响。

`GET /completion`与end/manifest成功返回统一摘要，字段如下：

`source=server_recorded, account_id, session_id, origin_connection_id, client_instance_id, epoch, end_key, status(ending|sealed), accepted_at, final_upload_deadline, sealed_at, input_revision, input_hash, coverage(pending|complete|incomplete), connection_count, gap_codes`。

ending时sealed_at/hash为null、revision=0、coverage=pending；sealed时revision=1、hash为小写SHA256、sealed_at非空、coverage为complete/incomplete。deadline固定30秒；source只说明服务端登记，不证明识别准确或可信终止。未登记GET返回404 completion_not_found。GET纯读，不能触发建连、续租、核验或固化写入。

## 双账本门、覆盖与固化

两追加接口必须同批增加门：父/连接存在与身份校验优先，已存event digest精确重放可在截止和seal后确认；任何新事件在`now >= deadline`或sealed时409 practice_input_sealed，混合批次整体失败。清单后未声明事件409 completion_manifest_conflict；同批既有映射/版本/容量规则仍适用。错误事务不能偷偷提交部分追加。

end、manifest和追加完成时可尝试提前固化；需要所有成员都有最终清单，且两账本实际ID/sequence/count/bytes与声明相符。明确tail/拒收等缺口不阻止固定输入，只使coverage=incomplete。仅首次end前已安全终结、epoch小于origin、无上游尝试且两账本为空的历史连接可记empty_not_started；origin即使end刚安全关闭也必须等待manifest；符合条件的历史连接不强求不存在的客户端清单；其他未申报连接不能当完整。

到期由maintenance独立扫描ending，按既有有界批次/skip_locked与锁后重查固化实有记录。进程重启继续，不依赖客户端。后台调度延迟不放宽写入30秒截止。GET仍可在后台尚未运行时显示ending，客户端只读refresh有界轮询，不能自延截止。

每连接保存不可变snapshot JSON及hash，PracticeCompletion只保存全局摘要/hash与成员身份，不在单响应放全部连接正文。`GET /connections/{cid}/completion`返回该scope当前覆盖（未固化仅临时视图）或已存snapshot，始终recoverable=false。包含原scope、sealed、input_revision、input_hash、coverage、gap_codes、manifest_received、tail_status、两ledger declared/received统计、missing_event_ids/unexpected_event_ids和turns引用。每ledger received统计last_sequence/total_events/total_text_bytes。单scope上限沿用两账本；引用不复制正文。

缺口代码固定：manifest_missing、transcript_missing、playback_missing、transcript_unexpected、playback_unexpected、manifest_totals_mismatch、transcript_rejected、playback_rejected、unfinalized_turn、unconfirmed_response、journal_unavailable、tail_unconfirmed、tail_aborted、playback_revoked、playback_unconfirmed。只根据实际映射/清单推缺口，不从sequence、turn index或revision跳号推断丢失。全局gap_codes为成员缺口去重排序。

hash canonical JSON包含schema/policy版本、原scope、按ledger/sequence排序event_id与既有event_digest、固定manifest、覆盖/缺口和turn引用。全局hash覆盖按epoch/id排序的成员身份及各snapshot hash，不包含动态终止状态。固化输入revision=1不可变；同event精确重放不改hash或时间，无新增补录/再评价功能。

用户话轮取每turn最大final revision，空修订覆盖旧原话。turn引用包含turn_id/turn_index/role、transcript_event_id及revision；字段candidate_eligibility、policy_version=`final_text_candidate_v1`及reason_codes仅记录候选引用：非空用户final eligible/user_final_text；若manifest的unfinalized_turn_ids命中该turn则uncertain/unfinalized_turn；空final excluded/empty_text，AI excluded/assistant_text。这不是完整反馈资格或识别准确性认证；未来反馈须结合具体判断依赖的上下文/质量疑点重新派生，不能仅凭candidate eligible。没有confidence不排除正常用户原话，其他turn的缺口不否定全部内容。AI生成与播放分开：只有与最新final同版本/正文的partial/played证据可作为final_prefix引用，旧首次freeze的非撤销可靠前缀单独作为interrupted_prefix引用，不迁移到新final；revoke排除两类。冻结前缀允许源为interim。上下文引用保留原playback event/文字及播放revision，不自动重建供应商上下文。

`GET /connections/{cid}/completion-receipt`只在sealed后返回（未固化409 completion_not_sealed）。严格字段source=server_recorded、account_id/session_id/connection_id/client_instance_id/epoch、sealed=true、recoverable=false、input_revision=1、input_hash（scope）、practice_input_hash（全局）、transcript_events和playback_events；两events只含原sequence/event_id，取自固化snapshot，容量同原账本。客户端凭此区分真实已收与永久未保存，不能伪造ACK。

原playback GET的sealed改为当前是否已有服务器固化，recoverable仍false。客户端严格page/history允许false→true，sealed后不得退回false或改变已固化统计/事件；旧未结束连接保持false。最终文字现行GET字段保持不变，通过completion摘要查询固化状态。

## 终止意图与父状态保护

end锁内，有完整not_started且没有offer/上游尝试的未终结连接可安全closed，原因ended_before_signalling；不把客户端申报当上游尝试。其他已尝试连接进入/保持unknown，并按原connection/attempt唯一登记TerminationCheck，status=blocked、reason=capability_unavailable、attempts=0，无外部调用。摘要/任务不能改termination_status为confirmed。

同样在信令失败及租约失效首次变unknown的事务登记；正常negotiating的termination_status=unknown不提前登记。维护批次有界补齐迁移前unknown且有上游attempt但缺任务的连接；重复扫描不重复建。任务只保留原scope/attempt摘要和时间，无正文；真实执行/重试策略待供应商能力验证后接入。

connections._expire/_restore_preparation_state、signalling._unknown不能覆盖ending/completed父状态。结束后禁止续租/新offer/新连接；晚信令答案保持原冲突保护，不能重开会话。sealed设置父completed/ended_at，但占用索引/准入和current recovery继续识别completed+unknown。真正删除父对象级联本批子数据；目前无删除HTTP，不创建绕过占用的删除入口。

## 客户端接入与资源归属

新增SubmissionManifestProvider独立接口，两个生产journal实现；不扩充原Realtime接口。每次成功入队保存无正文(sequence,event_id)及累计字节；ACK/finish后保留供清单，abort/账号变化同步清除。严格模型和仓库提供end/manifest/summary读取；HTTP仍原账号fork、8秒总截止含CSRF、失败暂停显式重试、固定key/body，不以响应更新本地媒体许可。

独立Listenable completion client在scope建立时构造，无副作用；requestEnd同步只标pending并排microtask。控制器正常end时安排意图，立即停麦停声并保持原3秒截止；即使transport/protocol drain抛错也保留意图。stop清冻结集合前收集所有!isFinal turn（含空TurnStarted）及未知输出response；finish两个journal后固定manifest，允许它先于end ACK排队。先end后manifest串行，manifest接受后只读refresh；遇practice_input_sealed也转只读refresh收敛，不无限重试已不可能成功的新清单。ACK不得重写清单。当前到期tail=unconfirmed，提前异常停止=aborted。

普通异常stop/background/page_left尚未收到正常end意图时继续原中断/安全清理语义，不擅自变成产品正常结束；客户端消失后的核验由租约unknown任务登记，服务端自动产品end策略另行实现。账号变化/dispose取消原账号请求并清metadata，不借新身份补交；正常end后同账号离页保留end/manifest/等待固化或失败重试操作。provider的keepAlive增加completion.hasPendingWork，summary sealed后先读取并核对原scope及全局hash的completion receipt；原end重放已sealed时跳过新manifest直接取receipt。两个生产journal实现独立SealedSubmissionReconciler：按实际收到refs结清pending，未收到的记permanentlyUnsavedCount和sealed_unsaved错误，停止上传重试并释放正文，不计作成功ACK或普通拒收。取消在途请求并忽略晚ACK，metadata保留到abort。provider仅在receipt核对成功且两journal已确认或明确终结缺失后释放，不能因不完整seal保留永远无法上传的正文。网络不延长本地drain、不改releaseStatus或occupied。

## 验证

新增行为先RED再实现。后端覆盖精确key/manifest、跨账号/CSRF/原scope、锁后撤销、跨epoch、并发append/manifest/end/seal、固定截止与混合批次原子、旧版本freeze/revoke/空final映射、所有历史成员、占用不变及晚答案、维护重启/skip_locked和blocked核验任务。客户端覆盖metadata无正文/ACK后保留/abort清空、严格摘要、固定重试、8秒CSRF截止、drain抛错/账号变化/空输入和离页留存、封存分页。独立测试库实际Dart→HTTP→PostgreSQL验证两阶段、缺口及重放、跨账号与占用。全量API/Flutter/Node、格式/分析、迁移/metadata、Web/字体及独立规格/质量复核后更新交接；不提交、推送或部署。
