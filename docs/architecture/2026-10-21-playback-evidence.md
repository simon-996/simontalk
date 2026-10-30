# 原连接播放与中断前缀证据契约

日期：2026-10-21。已实现客户端申报的独立追加账本、确认队列及严格分页重建；对应[设计](../superpowers/specs/2026-10-21-playback-evidence-design.md)和[收尾契约第3节](2026-10-20-practice-completion-and-review-contract.md#3-自然插话后的文字与上下文)。同日后续已接入[正常end的补交/固化及封存凭据](2026-10-21-practice-finalization.md)，最终实测见[固化验证报告](../development/2026-10-21-practice-finalization-verification.md)，前批存取证据保留在[播放验证](../development/2026-10-21-playback-evidence-verification.md)。供应商准入、网关和归一化协议仍关闭，没有正式练习或播放历史界面。

## 接口与事件

`POST/GET /v1/practice-sessions/{sid}/connections/{cid}/playback-evidence`，本人鉴权；Web写入需Origin、CSRF和X-Account-ID，提供了X-Account-ID的读写均核对身份。POST含原`client_instance_id`、`epoch`和1–4条按sequence递增的events；锁序User→Practice→Connection，等待账号锁后重验撤销/禁用和原连接身份。

共同字段为`event_id/sequence/kind/response_id`，UUID规范化，序号为严格正32位整数。alignment/freeze另含`turn_id/turn_index/transcript_revision/generated_text/transcript_final/playback_revision/delivery_status/played_text/played_until_ms/evidence_source`。

| kind | 语义 |
| --- | --- |
| alignment | 一个已接受AI文字版本及其独立播放版本的自含快照；文字/播放revision均为正数 |
| freeze | 首次停止时原turn的自含快照，另含`stop_boundary_ms/reason`；reason为interrupted或normal_end，允许尚无字幕的空、非final文字revision0及unknown播放revision0 |
| revoke | 只有共同字段，其余省略或null；可先到的永久response墓碑，之后不再接收该response的新alignment/freeze |

生成和播放文字各最多8192 UTF-8字节，拒绝NUL及无效Unicode；整数拒绝布尔/字符串，额外字段拒绝。unknown须空播放文字、位置null、source unknown；not_played须final、空播放文字、位置0；partial须非空严格生成前缀和正位置；played须final、非空全文相同和正位置。已知状态的evidence_source须device_output_aligned。位置和停止上限为0–86400000毫秒。

来源固定`source=client_reported`，device_output_aligned仅描述适配器申报的对齐依据；收到或固化记录均不证明物理设备已输出或用户听见，也不证明可信终止或完整反馈资格。固化状态由独立completion查询，不由追加ACK推断。新文字版本不继承播放证据，原版本冻结前缀独立保留。

## 一致性、确认与容量

新sequence须高于已存最大值，允许缺口；同event_id的全部规范内容精确一致才重放确认，不新增记录或改received_at。整批原子接受。同turn的索引/response固定，同文字revision的正文/final固定，文字版本不得回退，final不得退回非final；播放revision及已知前缀/位置在同文字版本内不得回退，unknown不能覆盖已知事实。

response第一次freeze固定停止上限和原因，每turn只接受第一次freeze。停止上限须覆盖该response全部历史已申报播放位置；后续alignment只能属于已有freeze的turn且不得越界。revoke永久撤销原前缀资格，精确重放旧事件仍可确认。与[最终文字账本](2026-10-20-final-transcript-storage.md)在同一连接锁下双向核对turn/index/role/response、同revision正文和final位，并拒绝跨账本的final降级；独立队列可迟到提交较早的interim来源版本。

每连接普通alignment+freeze最多512条，revoke独立最多256条，turn/response各256，累计generated+played最多2MiB；精确重放不重复占预算，普通额度不能占用撤销槽。请求按实际分块限制512KiB、总接收5秒。表`playback_evidence`以原connection/client_instance/epoch复合外键绑定，迁移为`d41a7c9e2b60`；真正删除父连接/练习/账号时级联清理，不重建已删除父对象。

ACK包含source、原账号/练习/连接/客户端/epoch、last_sequence、total_events、total_text_bytes及请求原顺序acknowledged_event_ids，bytes只计generated+played。主要错误如下；通用身份、CSRF和字段错误沿用现有账号契约，错误输出不含正文。

| HTTP / code | 条件 |
| --- | --- |
| 409 playback_conflict | ID/sequence映射、来源、关联、冻结或前缀事实冲突 |
| 409 playback_sequence_stale / playback_revision_stale | 新序号未前进，或新事件使用无效的旧文字/播放版本 |
| 409 playback_revoked | 已撤销response的新事件 |
| 409 connection_identity_changed | client_instance_id或epoch不符 |
| 409 practice_input_sealed | 锁后已到首次end的固定补交截止，或服务器输入已固化；精确已存事件重放仍可确认 |
| 409 completion_manifest_conflict | 新事件不在原成员已固定清单内，或ID/sequence不符 |
| 429 playback_limit_reached | 连接事件、文字或关联容量超限 |
| 413 request_too_large / 408 request_timeout | 实际请求字节或总接收时间超限 |

GET的after_sequence为0–2147483647，limit为1–16；返回同身份/累计统计、带received_at的events、next_after_sequence、has_more及sealed/recoverable。sealed反映是否已有服务器固化，recoverable固定false。未固化时跨页不是冻结快照，后页可能出现revoke；客户端history允许false→true，sealed后不得退回false或改变累计水位/统计，尚未读完的页继续核验同一已固化账本。全部读完或sealed均不自动恢复上下文。

历史/unknown连接的原scope补交受双账本共同的截止/清单/seal门保护：首次end受理后固定30秒不顺延，清单到达后只收其中声明的未收ID/sequence，到期或固化拒绝新事件；已存精确重放仍可确认，混合批次原子失败。end、manifest及追加可核对覆盖后提前固化，不把声明水位当实收。固化可使父练习completed，unknown连接仍占用；准备清理仍只依据可信完整历史。

## 客户端与剩余边界

PlaybackEvidenceJournal只接收投影已applied的播放、首次freeze及revoke。freeze保留首次停止时原turn的来源文字和版本，不依赖文字journal先ACK；撤销先入队，再执行上下文失效的安全停止。成功入队事件的ID/sequence固定，每批4条，原账号ApiClient fork独立请求，8秒总截止包含CSRF。精确核对ACK才移除pending；失败暂停，显式retry保留原ID。

普通pending最多64条/256KiB，撤销有独立256槽，整个实例仍受服务端同等预算限制。成功入队另保留无正文ID/sequence和累计预算，ACK/finish后metadata继续供固定清单使用。finish停止采集并继续提交；abort同步清空metadata/正文并取消旧请求。正常end的账号作用域同时留存两队列和completion，直到确认或封存receipt明确收敛。receipt只确认实际refs；缺失pending计永久未保存并暴露sealed_unsaved，停止重试、取消在途并忽略晚ACK、清正文，不误报全部保存。metadata保留到abort。记录失败不阻塞本地停麦停声，Web刷新仍可能丢失未确认内容。

原连接GET仓库和不可变history保留旧来源、冻结前缀及撤销墓碑，跨页冲突或超量原子拒绝；不创建恢复上下文、不改原文字UI的AI播放unknown。真实Dart→HTTP→独立测试PostgreSQL已验证4条证据及1条final、旧前缀晚final保留、撤销/精确重放、他账号404和连接/租约/终止前后一致，临时数据已精确清理；完整检查与审查结果以验证记录为准。

服务端end、固定补交/seal、覆盖/缺口及候选话轮/原版本输出引用已接入；最终实测范围由固化验证报告记录。完整反馈资格、反馈任务、可信上游终止执行器及真实供应商对齐仍缺。输入固化和只读重建本身不构成跨进程媒体或上下文恢复能力。


2026-10-29新增[TTS候选对齐验证](../development/2026-10-29-qwen-tts-timestamp-verification.md)：独立TTS两次固定英文实测的词段索引不能当原文字符偏移；纯函数仅在单个完整供应商句末结果、原文匹配和音频时间范围通过时返回UTF-8候选边界。它不接入本账本，不证明设备输出、不触发`device_output_aligned`，也不恢复上下文或开放语音。
