# 原连接播放与中断前缀证据持久化

日期：2026-10-21。依据已确认的[收尾契约](../../architecture/2026-10-20-practice-completion-and-review-contract.md)第2/3节和用户持续开发授权。本批实现原账号/连接的客户端申报证据账本；供应商准入仍关闭，不引入付费调用。

## 方案与边界

采用独立追加账本，包含原生成版本的播放对齐、停止冻结快照及明确撤销。保持现有最终文字接口的语义和AI播放unknown。已比较直接给transcripts行加播放字段、仅存最终冻结前缀、独立追加账本：前者混淆旧版本/临时来源且改写已确认文字，第二种不能保存普通完整播放和撤销历史；独立账本能精确重放、保留版本和证据来源，并为后续结束水位提供输入。

`source=client_reported`表示设备端申报，`evidence_source=device_output_aligned`是适配器申报的依据类别。数据库收到记录不证明物理设备已输出或用户听见，不证明可信终止、反馈资格或服务端固化。实际供应商对齐仍待准入实测。

## 独立事件与接口

`POST/GET /v1/practice-sessions/{sid}/connections/{cid}/playback-evidence`。

POST含原`client_instance_id/epoch/events`，每批1–4条。共同字段`event_id/sequence/kind/response_id`；alignment/freeze另含`turn_id/turn_index/transcript_revision/generated_text/transcript_final/playback_revision/delivery_status/played_text/played_until_ms/evidence_source`。freeze再含`stop_boundary_ms/reason`，reason为interrupted/normal_end；revoke只有共同字段，其他字段省略或null，永久撤销原response资格。

| kind | 含义 |
| --- | --- |
| alignment | 已接受的AI文字版本与独立播放版本的完整事实；unknown允许明确保留缺证据 |
| freeze | 第一次冻结时每个原turn的自含source与播放快照，可在完整生成final前封存；不依赖另一个journal先ACK |
| revoke | 明确推翻对齐；可先于普通记录作保守墓碑，之后该response新alignment/freeze拒绝 |

正整数字段拒绝bool/字符串。文字合法UTF-8、无NUL，每段生成/播放各8192字节。known播放依据须device_output_aligned；partial是非空严格前缀、正位置，played须final且全文相同，not_played须final且空前缀/位置0；unknown为空前缀/位置null/source unknown。alignment文字与播放revision均正数；freeze可playback_revision=0，无字幕source revision0仅空且非final。

同turn的索引/response固定，同文字revision的generated_text/final固定；播放revision只在对应文字revision内单调，不能回退文字/输出位置。response的冻结停止上限和原因首次固定，每turn只有第一次freeze；后续新文字version不继承播放，原冻结前缀保持原来源版本。新对齐不得超过停止边界。revoke永久使该response不可重用，不以unknown覆盖已知证据代替撤销。

写入User→Practice→Connection锁序，锁后重验账号撤销/禁用及原epoch；整批验证提交，eventID精确重放不新增、不改received_at。同ID不同内容/sequence映射冲突、文字/播放修订冲突、改绑等固定409。与最终文字双向核对turn/index/role/response和同revision正文/final位，不能把用户原话登记为AI播放证据。原表AI delivery_status仍unknown。

每连接普通alignment+freeze最多512条、独立revoke最多256条、turn/response各256、累计generated+played最多2MiB；撤销槽不被普通额度占用。请求实际分块最多512KiB、接收5秒；GET limit1–16，按sequence分页。ACK同文字账本包含原身份、last_sequence、total_events、total_text_bytes和请求顺序IDs，bytes只计generated+played。GET另有received_at、游标、has_more，以及固定sealed=false/recoverable=false；单页统计一致，跨页没有冻结快照。读取不能当作最终固化或自动恢复上下文的凭证。

未知/历史连接可申报，不续租、不释放占用、不改终止/练习状态；准备清理仍只依据可信连接完整历史，客户端正文不冒充上游开始证据。账号/练习/连接真正删除时级联清理，不创建已删除父对象。后续服务端end/finalize必须同时引入适用此账本的补交截止和封存限制，本批不实现这些未来状态。

## 客户端与读取

独立models/journal/read-model，recordAlignment接收已应用的AI turn，recordFreeze及时采集第一次冻结时原turn，recordRevoke接收已应用撤销。每event自含原版本，ACK移除已确认payload不会丢依赖；普通pending64条/256KiB，revoke独立256槽、无正文。原ID与sequence只生成一次，4条批次、账号fork独立请求和8秒总截止含CSRF，失败暂停并提供显式retry。finish继续已排队内容，abort同步清正文及取消旧请求；Listenable使账号作用域同时持有文字和证据队列，均确认后允许释放。

媒体协调器只记录投影已接受的事实。首次freeze记录原response各turn，重复freeze不制造新事件；revocation先入队再执行因上下文失效导致的安全停止。记录失败只影响保存错误及缺口，不能伪造保存成功或阻塞本地停麦停声。默认provider装配真实HTTP journal，读取scope不发请求或开麦。

仓库新增严格账号/原连接GET读取；不可变跨页重建原版本、冻结前缀及撤销墓碑，冲突/超量原子拒绝。保持来源和未封存标记，不把新final继承播放，不把某页尚未出现revoke解释为完整可恢复。现有只读文字UI不改；不创建正式练习/历史占位界面。

## 验证和交付

先运行后端API、客户端models/journal和媒体接入失败测试再实现。覆盖严格schema/UUID/Unicode/字节、原scope/CSRF/撤销、并发/精确重放/批次原子、跨版本/跨final一致性、容量及撤销headroom、级联、准备清理不变；客户端覆盖精确ACK/丢ACK重放/超时、跨页迟到撤销、队列释放与账号变化。使用独立测试库实际Dart→HTTP→PostgreSQL运行存储与读取，比较前后连接/租约/终止不变；夹具与临时服务清理。最终全量API/Flutter/Node、分析/格式、Alembic迁移/模型比对、Web构建与独立规格/质量审查，交接明确供应商/真实设备与固化仍缺。
