# 持久反馈任务和结果契约

日期：2026-10-21。本轮实施契约，证据见[验证报告](../development/2026-10-21-review-jobs-verification.md)；依据[设计](../superpowers/specs/2026-10-21-review-jobs-design.md)与[原复盘输入](2026-10-21-review-inputs.md)。只实现后端任务与有效结果存取，默认模型不可用，不代表真实语言反馈或页面已验收。

## 1. 请求与唯一任务

POST `/v1/practice-sessions/{sid}/review`带Idempotency-Key及`input_revision,practice_input_hash,review_input_hash,policy_version`。本人鉴权、账号头/CSRF和User→Practice→Job锁后复验；只接受已存在的精确ReviewInput，generation策略由服务器固定为review_generation_v1。同一输入/策略只有一个job，不因新动作key并行再生成。

ReviewAction按本人/key记录规范请求摘要与job映射，包含操作、路径和body。相同key精确重放返回同job当前状态，不增加调用；同key换操作/路径/body为409 idempotency_conflict。不同key复用相同job也记录映射，不丢掉该key的约束。GET同路径纯读当前任务及有效结果，未建任务404；不自动创建或重试，均本人隔离/no-store。

POST `/review/retry`带新动作key、job_id、expected_attempts。重放不重复，次数不符409 review_retry_changed；只有允许的blocked/failed任务可重新排队。queued/running/retry_wait及已有成功/正常空结果不增加尝试；未知调用结果和总次数门不能通过新key绕过。两种POST在JSON前受8KiB与五秒接收边界保护，不提供客户端写结果或更换gateway入口。

三种端口返回相同任务摘要：`id,account_id,session_id,input_revision,practice_input_hash,review_input_hash,policy_version,generation_policy_version,status,attempt_count,next_attempt_at,error_code,outcome_unknown,created_at,updated_at,result`。POST返回202、GET返回200；`result`在有效成功/空建议之外为null。Idempotency-Key及job_id使用UUID；绑定hash为64位小写十六进制，输入版本为严格整数，retry期望次数限定0–3。缺ReviewInput返回404 review_input_not_found，绑定改变409 review_input_changed；来源/结果完整性不符不返回旧正文，结果错误为409 review_result_invalid。

## 2. 状态与模型边界

| 状态 | 含义 |
| --- | --- |
| queued / running / retry_wait | 已登记待执行 / 已领取 / 明确安全错误的有界退避 |
| blocked | 当前生成能力不可用，正常默认配置为capability_unavailable、0次调用 |
| succeeded / no_suggestions | 有经校验建议 / 有效空建议；空建议不等于证明没有语言问题 |
| no_evaluable_content | 原输入没有可评价内容，不调用gateway |
| failed | 技术失败，是否可明确重试由剩余次数与未知结果规则决定 |
| invalidated | 来源、输入版本或账号条件已失效，不再接收旧结果 |

gateway是异步服务依赖，默认Unavailable；只有显式配置才能取得能力。首次可执行时固定config_id及已验证的供应商幂等能力，后续配置变化不能悄悄继续。输入只包含允许的用户目标、依据和同scope安全前文，不发送排除正文或账号凭证。当前实际验证使用测试注入，不含真实供应商适配或付费授权。

## 3. 执行、重启与重试

ReviewJob保存固定输入/生成策略、attempt_count≤3、到期时间、当前lease/fence和错误码；ReviewAttempt保存每次调度及可追溯的无正文元数据。领取事务按User→Practice→Job锁并复核来源，提交running/attempt和15秒lease后离开事务；外调前再以独立短事务按同序锁复验running/token、原lease、账号启用及精确输入来源，来源核验后再检查lease，不延长租约或重置尝试。复验通过并结束事务后才等待gateway，最多8秒；复验与外调之间的跨系统非原子窗口仍存在，不承诺分布式原子性。回写重新锁定并核对当前token、lease、来源存在/有效、输入hash/policy和原话资格，完整通过后一次保存结果及终态。

旧worker或超时/过期回调不能覆盖新尝试。明确可安全重试的临时错误以2/8秒退避，合计最多3次；非法输出和永久错误不盲目循环，明确重试仍计入上限。超时、未知异常或过期running记录outcome_unknown；无已验证幂等能力时禁止自动及手动再次调用。只有经验证的能力才允许复用固定logical job请求key有限重试，每次fence保持独立；不承诺上游exactly-once。

ReviewJobRunner在API lifespan运行有界周期扫描，任务状态和租约在数据库中，进程重启不依赖原内存。多worker靠行锁与fencing协调；网络不占数据库长事务。候选之间及dispatch前均检查停止请求，停止后保留已领取尝试供租约恢复；正常shutdown在有界请求结束后停止并释放私有池，原PracticeMaintenanceRunner保持独立。默认blocked不因轮询、重启或再次打开页面自动调用。

## 4. 结果及保留范围

ReviewResult按job唯一，版本1/hash固定；建议0–3项均先通过`validate_review_suggestions`，保留稳定item UUID/ordinal、原source连接/turn/revision/exact_quote、kind/basis及解释/建议。任何引用或结构错误整批拒绝，不保存未经校验的原始模型响应。GET重核输入、引用和result hash后才返回有效结果；这仍不能证明语言建议正确、原音准确或提供发音分数。未来页面须说明建议基于本次识别文字。

结果对象包含`schema_version:review_result_v1,version:1,job_id`、上述四项输入绑定及generation策略、`items,result_hash,created_at`。每item为`id,ordinal,source_connection_id,source_turn_id,revision,exact_quote,kind,basis,explanation,suggestion`；ordinal从1连续，kind为correction/polish/extension，basis为text_only/conversation_context且须在该原话允许集合。空建议仍保存有效版本/hash，items=[]；不可评价没有结果对象或调用。

练习删除级联清除任务、请求和反馈正文；晚结果不得恢复。ReviewAttempt保留source_job_id、owner、输入hash、运行key/配置/次数/状态和可选用量，关联job置null，不存prompt、原话或异常正文。账号清理可级联。未知用量保持null/unknown，不填0，也不把这些元数据称为完整计费账本、额度控制或费用封顶。

当时没有用户删除HTTP；2026-10-23已按[删除契约](2026-10-23-practice-deletion.md)接完整范围确认和产品接口，queued/running/已派发结果晚到及无正文attempt保留均有回归证据。正式复盘阅读页已有，真实模型和一级重练客户端仍待后续。完整用量、供应商适配与语言质量人工验收仍需后续。

配套[原账号Dart复盘客户端](2026-10-21-review-client.md)已提供严格绑定/结果模型、明确创建、纯读刷新及固定动作确认；其账号family构造/监听不发请求，尚未接正式页面，不改变本契约的模型和费用边界。
