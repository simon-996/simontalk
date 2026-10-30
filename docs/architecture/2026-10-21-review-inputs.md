# 复盘输入资格、存取与引用门

日期：2026-10-21。本轮实施契约；验收结果见[本轮验证](../development/2026-10-21-review-input-eligibility-verification.md)。依据[设计](../superpowers/specs/2026-10-21-review-input-eligibility-design.md)与[集中契约](2026-10-20-practice-completion-and-review-contract.md#5-反馈依据与不确定性)。仅实现可用证据范围的服务器派生，不生成模型反馈或改变媒体/占用状态。

## 1. 输入身份与生命周期

旧completion的final_text_candidate_v1及不可变hash保持原样。复盘输入以`review_input_v1`独立绑定本人session、input_revision=1、practice_input_hash，保存所有纳入/排除话轮的原scope/event/revision及决定；review_input_hash固定这一策略投影。存储快照不复制文字，原文/已播前缀只从原封存实收refs解析。读取和内部引用校验重新核对身份、hash及原事件内容，不取后来的“最新记录”代替。

ReviewInput归属Practice并受外键级联清除，联合键为session_id/input_revision/policy_version。当前只有固定输入版本1与策略v1；以后改变输入或规则须显式建立新版本并使旧任务失效，不能静默重新解释已有建议。后续单元已接入[受此门约束的持久反馈任务](2026-10-21-review-jobs.md)，默认模型仍不可用；当前尚无用户删除HTTP，级联约束不代表删除产品已实现。

## 2. 本人接口

| 操作 | 契约 |
| --- | --- |
| POST `/v1/practice-sessions/{sid}/review-input` | body仅`input_revision:1,input_hash:<原全局seal hash>`；服务器选择policy。鉴权/账号头/CSRF，User→Practice锁内核对seal；首次生成及精确重放返回200，不重新建立记录或付费；仍重新派生核对来源 |
| GET 同路径 | 纯读，不存在404 review_input_not_found；不创建输入或任务 |
| 未封存 | POST 409 completion_not_sealed；不伪造空输入 |
| 身份或版本已变化 | 他账号练习404 practice_not_found；错误input版本/hash返回409 review_input_changed |
| 预算超限 | 409 review_input_limit_exceeded，不截断、不影响正常结束 |

沿用账号401/409及Origin/CSRF规则，响应no-store，不泄露他账号内容；POST在JSON解码前受8KiB与五秒接收上限保护。输入无可评价文字时仍是成功存储的`no_evaluable_content`业务结果，不自动重试模型。

响应包括source=server_derived、evidence_source=client_reported、policy_version、account/session、原input_revision/practice_input_hash、review_input_hash、created_at、status、counts及scope决定。scope绑定connection_id/client_instance_id/epoch；每个决定保留turn/revision/event与摘要、eligibility、reason_codes、allowed_bases、confidence=null、quality_source=unavailable。只有可评价用户项解析text和安全的context_before，排除项不成为用户目标。上下文按精确原事件解析并受相同预算保护。

## 3. 资格与可用依据

最新非空用户final默认eligible，缺失confidence不排除；不以语法正确与否判断识别质量。旧修订、AI和最新空文字均excluded，空修订不回退旧非空正文。清单还记为未final的实有文字为uncertain；无final的清单turn保留无正文排除项，不猜测它的说话人。

`text_only`允许有限的独立文字建议；`conversation_context`要求该turn之前的原scope历史可核对。真实文字/播放缺失、未知播放、撤销或未final等使受影响的后续判断受限，不自动废弃更早正常话轮，也不排除其独立文字判断。纯tail_unconfirmed或sequence空洞本身不推导整场无效；跨epoch不假设接续上下文；conversation_context仅表示该scope内前文可核对，不认证完整跨代会话历史。

AI仅作背景。首个freeze保留原版本固定played_text边界，优先于后来的final重写；否则采用snapshot选择的final_prefix。不得加入生成后缀、跨版本拼接或未来话轮。明确not_played只省略，unknown/撤销/不确定收尾保留缺口。实际playback缺口和unconfirmed_response事实不能被“已有一个partial前缀”抹去。

这套规则不检测当前未提供的ASR低质量或语义歧义，不认证原音逐字准确、真实设备输出或发音；后续供应商适配器只能添加实际获得且语义验证过的信号，不能伪造统一分数。

## 4. 内部建议校验

后端反馈任务调用`validate_review_suggestions`并绑定本人session、input_revision、practice_input_hash、review_input_hash和policy，结果读取仍复核同一门。当前不公开允许客户端提交假反馈的POST。

输入最多0–3项，每项要求source_connection_id、source_turn_id、revision、exact_quote、kind、basis、explanation、suggestion。kind仅correction/polish/extension，basis仅text_only/conversation_context；不接收pronunciation类型。精确连续引用不做Unicode或空格归一化，角色/资格/版本/scope/原文和允许basis必须全部匹配；任一非法整体拒绝。仅结构/引用通过不能证明建议语义正确，未来页面仍须提示“建议基于本次识别文字”。

## 5. 资源与当前边界

工程上限：32个成员、8192个源事件、4MiB源文字、512KiB展开输入。查询先统计/限界，再加载；context_before重复文字也计入展开预算，避免无界复制。错误不产生部分记录或隐式截断。此输入接口不调用模型或自动建立反馈任务；持久反馈任务另有本人端口，配套[客户端](2026-10-21-review-client.md)也仅在明确动作中分步请求。没有Web持久正文、正式复盘页面或完整历史；可信终止与unknown占用继续按原契约独立处理。
