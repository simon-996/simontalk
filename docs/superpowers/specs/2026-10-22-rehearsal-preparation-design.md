# 一级重练来源、目标与独立准备记录

日期：2026-10-22。承接[收尾与重练契约第6节](../../architecture/2026-10-20-practice-completion-and-review-contract.md#6-一级重练评价与删除)、[有效反馈任务](../../architecture/2026-10-21-review-jobs.md)及[原话定位](../../architecture/2026-10-22-saved-transcript.md)。本单元执行现有D18/D20，采用默认来源原意，不新增情境选择。持续工程授权覆盖常规可逆实现，保留当前dirty功能分支，不提交/推送/部署，不调用真实供应商、不构建原生。

## 1. 本单元与方案

交付服务端可接入的重练目标纯读、确认目标后创建独立练习准备、读取固定目标和同级重练列表。每次明确动作有独立会话及配置快照，同key重放不重复创建，同句可多次练。来源必须为本人的普通练习及当前有效建议，不能从重练结果继续派生。既有占用/偏好/准入照常核验，默认Unavailable拒绝创建，不绕过未知连接。

本批不增加客户端按钮/页面、媒体调用、重练改善评价、费用账单或删除产品接口。现有Flutter阅读功能保持；下一单元再将真实API接入目标确认和准备页面。服务端基础不冒充完整重练或学习闭环。

| 方案 | 取舍 |
| --- | --- |
| 在普通练习配置里放松散来源ID | 迁移少，但一级限制、跨账号和删除级联缺少结构约束 |
| PracticeSession显式kind及同账号普通父记录外键（采用） | 复用既有独立会话、占用与媒体生命周期，数据库可防跨账号/多级并级联真实子练习 |
| 独立重练草稿表，未来再转练习 | 会引入两套创建/恢复状态，当前不能证明独立练习已真实创建 |

## 2. 结构与原有契约

PracticeSession的`mode`仍为`free_chat`（对话模式），增加`kind=ordinary|rehearsal`（记录类型，默认ordinary）。增加nullable的`source_session_id`、`source_kind`、`source_review_item_id`、`rehearsal_target` JSONB、`rehearsal_target_hash`。ordinary这些字段全null；rehearsal全部非null、source_kind固定ordinary、source_session_id不等于自身、hash为小写64hex、target为JSON对象。所有历史记录迁移为ordinary，不改原配置/正文。

保留原(id,user_id)唯一键，另建(id,user_id,kind)唯一键；子记录(source_session_id,user_id,source_kind)复合外键指向它，ON DELETE CASCADE。数据库即拒绝跨账号、以rehearsal为父、自引用/循环，以及有子记录时将ordinary父类型改掉。删除普通练习会删除真实子PracticeSession及其现有级联数据；删子不会动父/同级。产品删除的确认范围、终止核验/占用保留仍属后续接口，不能把直接数据库删除测试当产品删除完成。

PracticeOutput保留现有字段并增加kind、source_session_id、source_review_item_id；不直接暴露完整target JSON。现有普通准备/恢复/连接/保存契约保持；Flutter尚未接新类型入口，本批不创建开发库示例重练。

现有`create_preparation`只支持普通练习输入，不能接受kind/source/target。将其占用/偏好/准入/配置创建的共同部分提取为小型不commit的构造helper；旧普通wrapper仍完成原key核验与单次commit。新重练在同一事务创建完整PracticeSession和目标快照，禁止先commit普通准备再补关联，避免半条记录。不得复制一套会分叉的占用或准入门。

## 3. 目标冻结与来源门

来源GET不创建ReviewInput/Job/练习，不commit、不续租、不调用模型/admission/signalling。先本人ordinary来源，再复用`read_review_job`的当前policy、源payload/member/global/input/result hash和精确quote门，仅succeeded中的实际item可用。沿`read_review_input`匹配同connection/turn/revision的非excluded用户decision，取完整source_text和需要的安全前文，不能只按turn UUID或用户上传quote选句。

目标为`rehearsal_target_v1`，固定字段如下；快照不含target_hash自身，按既有canonical+digest产生hash，返回时追加target_hash。所有UUID规范化，revision/epoch正整数，正文合法UTF-8、无NUL，单段源文字/quote/suggestion<=8192字节、explanation<=16384字节（原结果上限4096字符）；整体实际JSON<=64KiB，超过明确409而不截断目标/前文。已有源读取32成员/8192事件/4MiB/展开512KiB限额保持。

```text
schema_version: rehearsal_target_v1
source: server_derived
evidence_source: client_reported
account_id, source_session_id, source_kind:ordinary
item_id, job_id, result_hash
input_revision:1, practice_input_hash, review_input_hash
policy_version:review_input_v1, generation_policy_version:review_generation_v1
source_connection_id, source_client_instance_id, source_epoch
source_turn_id, revision, source_text, exact_quote
kind:correction|polish|extension, basis:text_only|conversation_context
explanation, suggestion, situation_mode:source_original
context_before:[{ledger,event_id,event_digest,turn_id,turn_index,role,revision,text}]
target_hash
```

text_only的context_before为空；conversation_context只用原decision已允许的同scope安全前文，不加入AI未播生成后缀。source_text是完整最终用户段，exact_quote为该段精确非空子串。默认按原表达意思练习；没有模型推断的新意图/情境，不把示例句或目标快照写入子练习的转写账本，也不据目标存在宣称已表达/已改善。

未知本人来源/item404；来源类型、无成功结果、版本/输入/结果/目标变化409 `rehearsal_source_changed`；超过目标或原来源预算409 `rehearsal_target_limit_exceeded`。错误不回显正文/内部异常。完全无job、succeeded结果中无item及有效空结果no_suggestions为404，其他非成功job为409。两种GET的鉴权和X-Account-ID沿原session_identity。

## 4. 本人API

### 只读来源目标

GET `/v1/practice-sessions/{source_session_id}/review-items/{item_id}/rehearsal-target`，无body，返回第3节完整目标。不要求本人当前已选难度，查看目标不分配练习或媒体。

### 明确创建

POST同来源`.../review-items/{item_id}/rehearsals`，必带Idempotency-Key；严格body只有`target_hash`及可选`difficulty_override`（沿beginner/intermediate/advanced）。创建路由沿protect_mutation和locked_identity，在User→来源Practice锁序下复验本人ordinary及完整当前目标，再比较用户确认hash；不能用客户端正文、其他item或旧hash创建。

请求摘要绑定操作、父路径/item和完整body，同owner的PracticeSession.creation_key沿原唯一约束共享。相同key但其他来源/item/hash/难度或普通创建为409 idempotency_conflict；先查key摘要避免同key换目标被误当普通来源变化。原动作重放仍要核对来源/目标有效及已存快照，然后返回同一独立会话当前状态，不再admit/不续租/不改时间；没有按item去重，新的动作key可在上次安全结束后创建新的同级记录。

新创建核对所有本人活跃PracticeSession和OCCUPIED_CONNECTION_STATES，未知占用照常409 practice_in_progress；偏好未选沿preferences_required；admission默认503 realtime_unavailable，且不留下半条练习或目标。只有准入通过才原子保存kind=rehearsal、父/item及固定target/hash。返回201（重放同201）：

```text
schema_version: rehearsal_preparation_v1
source: server_recorded
account_id
practice: PracticeOutput（含kind/source_session_id/source_review_item_id）
target: 完整rehearsal_target_v1
```

POST新路径加入现有请求前8KiB/五秒接收门；不要扩大其他路径的限制或重写中间件。账户撤销/禁用在User锁后重新核验，Web写保留Origin/CSRF/X-Account-ID规则。

### 子记录固定目标

GET `/v1/practice-sessions/{child_session_id}/rehearsal-target`，先本人rehearsal记录及已存snapshot/hash结构，重读当前父目标完整门，并与冻结快照逐字段一致才返回。ordinary记录404；来源/结果/快照失效409，不回旧原话。来源删除则子记录由FK级联为404。来源建议后来失效不删除子练习：原GET练习/自身保存文字仍可按已有规则读，不能给依赖旧目标的确定评价。

### 同级记录分页

GET `/v1/practice-sessions/{source_session_id}/rehearsals`，先本人ordinary来源；可选limit（1–20，默认10）、before_id UUID。按(created_at,id)倒序seek，游标必须属于同账号/同父的rehearsal，错误游标404；多取一条决定next_before_id，不做无界读取。返回`schema_version=rehearsal_list_v1`、`source=server_recorded`、account_id/source_session_id、limit、next_before_id|null和items；item只有id、kind=rehearsal、source_session_id、source_review_item_id、status、created_at、ended_at，不含quote/目标正文或虚构用量/时长。保留取消/失败的实际独立记录。读取列表不要求当前反馈依然成功，父存在且ordinary即可；目标查看须重新走上面的完整门。列表GET零业务写/媒体/模型调用。

## 5. 迁移、验证与下一单元

单个新迁移在8b2731f5ca90之后增加上述列/约束，不增加表。downgrade仅在没有rehearsal行时允许，非空拒绝避免静默丢失关联/目标；空库可降回旧head再升，metadata完全一致。开发库只在独立测试/双审通过后升级，保留17表计数及原普通数据，默认API按新代码重启且全部gateway仍Unavailable。

测试先真实404 RED，再目标/创建/复放/不同key同级/占用/默认准入/当前偏好与override快照/来源与快照删改/多scope同turn/安全AI前文/纯读全行不变、锁等待撤销/禁用/创建与父删除、DB跨账号/多级/父级联和子独立删除、seek分页、body/time门、普通准备回归。独立规格后质量审查，root另跑完整API/Ruff/metadata、隔离真实HTTP及迁移降升，精确清理临时账号/库/凭证/服务。

本批没有新界面，不需要借旧截图声称重练页面已验；Flutter代码不改，不将上批773/Chrome163记为本批重跑。浏览器工具上批被Work设置禁用，保存文字页实际验收仍单独待补。下一单元接目标确认/独立准备页面与原记录返回，再接真实媒体和双维度改善判断；完整历史/删除产品流程仍未完成。
