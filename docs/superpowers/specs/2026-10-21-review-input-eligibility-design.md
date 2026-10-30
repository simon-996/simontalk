# 封存后的复盘输入与引用资格

日期：2026-10-21。依据[集中契约第5节](../../architecture/2026-10-20-practice-completion-and-review-contract.md#5-反馈依据与不确定性)和[现有固化](../../architecture/2026-10-21-practice-finalization.md)。用户已授权持续工程推进，沿用原工作区及全部未提交改动；不提交、推送、部署、调用供应商或恢复原生构建。

## 范围与方案

采用封存后的独立、持久、确定性复盘输入。直接复用candidate_eligibility不足以约束上下文或精确引用；重写旧completion快照会改变已固定hash；因此保持旧seal不变，以`review_input_v1`从原实收事件/快照生成新投影，并独立绑定原input_revision/hash。只实现当前可用证据的资格，不宣称已识别语义歧义或ASR低质量；质量信号未提供时明确confidence=null/quality_source=unavailable，不编造分数或按语法是否规范筛掉句子。

本单元不生成反馈、不新增占位页面或模型调用。公开API只生成/读取本人输入，反馈输出检查为后端内部函数，防止客户端自行提交假反馈。其后再接反馈任务与页面。

## 冻结与存储

新增ReviewInput表，以session_id/input_revision/policy_version联合主键，归属本人Practice，保存practice_input_hash、review_input_hash、无正文snapshot和created_at。约束revision=1、固定策略、合法hash、归属外键及级联删除。新Alembic迁移只增加该表，不重算旧completion/hash。

POST `/v1/practice-sessions/{sid}/review-input`请求仅`input_revision=1,input_hash`，本人鉴权/账号头/CSRF，按User→Practice锁序核对sealed及精确hash；策略由服务器指定。首次生成、后续同版本/hash精确重放返回相同记录，不重新调用模型或改变seal。未封存409 completion_not_sealed，版本/hash不符409 review_input_changed；错误不暴露他账号内容。GET同路径纯读，不存在404 review_input_not_found，本人之外404 practice_not_found；均no-store。POST在JSON解码前受8KiB与五秒接收上限保护。

snapshot仅保存所有纳入/排除的具体连接/turn/revision/event引用、原事件摘要、原因、允许判断依据和安全上下文引用；正文仍从原账本按精确封存refs解析。读取/内部使用都重新核对归属、原input/hash、存储投影hash及引用；异常拒绝，不猜测或读取最新未封存修订。创建失败整体回滚，没有部分记录。临时实施预算最多32个成员、8192个源事件、4MiB源文字、512KiB展开输入；先界定查询/字节再加载，超过返回409 review_input_limit_exceeded，不静默截断或影响正常结束。

## 资格与上下文

- 按原连接/epoch顺序处理封存refs，保留所有最终文字版本的决定。较旧修订excluded/superseded_revision；AI文字excluded/assistant_text；空最新用户文字excluded/empty_text，不能退回旧非空版本。
- 最新非空用户final且来源/顺序一致为eligible/user_final_text。清单还声明该turn未final时为uncertain/unfinalized_turn，仍允许基于实有文字的text_only判断；不证明它是完整原音。没有final的清单turn另记role=unknown、revision/event=null、excluded/missing_final_text，不猜测说话人。
- 关键上下文无法核对时，受影响的用户turn为uncertain/context_incomplete，仍允许text_only，禁止conversation_context判断。会话尾部tail_unconfirmed本身不降级更早已完成的正常句子；纯数字序号空洞不推导丢失。实际transcript_missing/rejected/unexpected、manifest_missing/totals_mismatch、journal_unavailable等无法定位的文字缺口使原成员上下文受限；新epoch不假设继承旧epoch上下文；conversation_context仅指该scope内已核对前文，不宣称跨代历史完整。
- AI只可作为上下文，不可成为用户评价目标。使用封存snapshot已选的可靠final_prefix或interrupted_prefix；有首次freeze时优先保留其固定边界，即便后来final升版也不拼接扩展。从对应playback实收事件取实际played_text，绑定原revision，不取生成后缀、推算前缀或继承另一版。明确not_played省略而不假称未知；撤销、未知播放或未final用户输入留下上下文缺口，对后续依赖该历史的判断持续限制，不污染更早话轮。
- 对每个可评价用户turn保留允许的依据`text_only`，只有该turn之前同scope上下文完整时才附`conversation_context`和安全的context_before引用。排除项不进入模型目标，生成文字和未来话轮不进入它的上下文。所有依据仍是client_reported，不认证设备输出或原音准确。

## 输出和引用门

API返回server_derived策略、account/session/input_revision/practice_input_hash/review_input_hash/policy_version/created_at，status为ready或no_evaluable_content、三类计数和各scope决定。可评价项解析原文与context_before；排除项只给原因和引用，不作为用户目标。无可评价内容是稳定业务结果，无自动重试。

内部`validate_review_suggestions`按本人、session、原input_revision/hash、review_input_hash及策略绑定读取输入，再验证最多0–3项完整结构：source_connection_id/source_turn_id/revision/exact_quote、kind=correction|polish|extension、basis=text_only|conversation_context、explanation和suggestion。quote须非空且是该精确用户版本的连续原文；不做Unicode/空格归一化，不接受AI、旧版本、空/排除项、其他scope或不允许的context依据。任一项非法整体拒绝，不能局部展示。验证通过只表示结构/来源/依据可用，不能证明语言建议正确、原音准确或发音评分；不提供pronunciation类型。

## 验证与后续

先写RED，覆盖资格、旧修订/空覆盖、缺置信度、局部缺口、旧freeze/新final、撤销、unknown与not_played、未final无正文、跨epoch/账号/删除/不匹配hash、幂等/并发、纯读/CSRF和无可评价。引用门覆盖精确Unicode、错误角色/版本/quote/basis/类型/数量及整体拒绝。新迁移在测试库降升/metadata，再保留开发库升级。

独立规格与质量复核、完整API和静态检查；以独立测试库实际HTTP核验创建/重放/读取/隔离/无输入，不用默认库假记录。客户端和UI本轮不变，既有Flutter/Node/Web证据保持其时点；实测报告说明本批后端范围。完成后同步HANDOFF及契约，下一步为受此门约束的反馈任务，账号/预算/设备继续暂缓。
