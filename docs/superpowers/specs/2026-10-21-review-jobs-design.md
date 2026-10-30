# 持久反馈任务、尝试与有效结果

日期：2026-10-21。依据[复盘输入](../../architecture/2026-10-21-review-inputs.md)、[集中契约第5节](../../architecture/2026-10-20-practice-completion-and-review-contract.md#5-反馈依据与不确定性)与技术设计的持久任务/有限重试要求。持续工程授权已明确；复用现有工作区，保留所有未提交改动，不提交/推送/部署/调用供应商或恢复原生。

## 范围与选择

采用专用于review的数据库任务、尝试、请求幂等及结果，不引入通用任务平台。只用FastAPI BackgroundTasks不能保证进程恢复；把模型请求放在事务内会阻塞账号操作，因此使用短事务领取、事务外异步生成、短事务核验提交。当前缺少模型权限和预算，默认gateway必须Unavailable，正常输入任务blocked/capability_unavailable、attempts=0；空输入直接no_evaluable_content。测试gateway只在独立测试环境注入，不写默认开发库假反馈，不代表真实语言建议验收。

## 身份、请求与存储

新增ReviewJob、ReviewAttempt、ReviewResult、ReviewAction四类表，单迁移。任务绑定user/session、原input_revision/practice_input_hash/review_input_hash/policy_version及服务器generation_policy_version=review_generation_v1；一个输入/策略仅一个job。原输入和旧seal不改写。

ReviewAction按本人/Idempotency-Key唯一，保存操作类型、规范request digest及关联job。创建/重试的重复key不触发新尝试；同key用于其他路径、操作或body返回409 idempotency_conflict；不同key指向同输入仍复用job并记录请求映射，不能绕过重复调用门。

ReviewJob保存状态、attempt_count≤3、next_attempt_at、当前lease/run_token、固定gateway配置（首次可执行时捕获）、错误码和时间。ReviewAttempt记录每次真正调度的ordinal、独立fencing token、原logical job请求key、配置、起止/租约、结果分类及可选gateway报告用量，不存prompt/原文/原始模型响应/异常文本。ReviewResult按job唯一保存不可变版本1/hash和0–3个经核验item，item有稳定UUID及ordinal供后续来源引用。

任务/结果/请求随来源练习级联清除。尝试以可空job FK SET NULL保留无正文source_job_id、owner、输入hash、请求key、配置、次数与未知用量事实；账号清理可级联。练习删除不能通过丢掉尝试记录伪造未发生调用；此记录仍不是完整计费账本或额度保证。

## 本人API

- POST `/v1/practice-sessions/{sid}/review`：Idempotency-Key必需，body为input_revision、practice_input_hash、review_input_hash、policy_version。必须已有精确ReviewInput；User→Practice→Job锁序、鉴权/账号头/CSRF及等待锁后复验。创建/重放202返回同job摘要，无外部调用。无输入明确404，绑定改变409 review_input_changed。
- GET同路径：纯读当前输入对应job及已核验结果，未建job 404 review_job_not_found，不自动创建、重试或扫描。全部本人隔离/no-store，错误不泄露他账号。
- POST `/review/retry`：新动作key，body为job_id与expected_attempts。精确key重放不重复；新key仅在该job允许且次数匹配时重置blocked/failed为queued或仍blocked。queued/running/retry_wait/success等不再加尝试；旧次数409 review_retry_changed。耗尽、未知且无幂等能力不能借新key重试。

创建/重试请求在JSON前受8KiB和五秒接收门。客户端不可选择gateway、提交结果、修改任务状态或放宽资格。

## 任务执行与重启

状态为queued、running、retry_wait、blocked、succeeded、no_suggestions、no_evaluable_content、failed、invalidated。succeeded、no_suggestions、no_evaluable_content三种内容结论分别表达有建议、无建议、无可评价；failed为技术失败，invalidated为输入/来源不再有效，均不伪造成功。

异步ReviewGateway提供可信配置标识、经验证的logical-request幂等能力和generate能力。默认capability=None；首次可用时固定配置，后续配置不一致拒绝继续。生成payload只含非excluded用户目标、允许basis和相应安全context_before，不含账号凭证或排除正文。logical request key固定为job身份，重试不换；每次运行的fence token独立。

worker有界取候选并按User→Practice→Job短锁复核来源/配置及资格，持久attempt、running、15秒lease后提交，在外调前再以独立短事务按同序锁复验running/token、原lease、启用账号及精确输入来源，来源核验后再次检查lease；不延长租约或重置尝试，复验通过并结束事务后才调用gateway，**8秒总等待**。复验与外部调用之间仍有跨系统非原子窗口，不承诺分布式原子性。外部请求期间无DB长事务；回写时再锁同序，核对job仍存在、当前run_token、lease未过、输入版本/hash仍有效，调用validate_review_suggestions后一次原子保存完整结果/hash及job终态。任一项错整批失败，不存未经核验正文。超过时间即使回调迟到也不能提交；旧worker不能覆盖后来尝试。

可明确安全重试的临时错误自动retry_wait，退避2/8秒、总共最多3次；非法输出/确定的永久失败进入failed，允许明确重试但不能绕过总上限。异常、超时及租约失效若无法确认调用结果，保留outcome_unknown；没有经验证的供应商幂等能力时不自动也不手动再调用，不声称外部exactly-once。具备幂等能力才可复用同logical key作有限重试。用量缺失保持unknown/null，不填0，不宣称已结算或费用封顶。

独立ReviewJobRunner在API lifespan周期扫描持久queued/retry_wait/expired running，多进程靠行锁与token协调；进程重启不丢任务，过期running按上述未知规则恢复。无候选或默认Unavailable不做模型请求。批次有限，stop检查覆盖候选之间及dispatch前，停止后保留未外调的已领取事实供租约恢复，HTTP超时受限；正常shutdown停止worker并释放私有池，不影响现有媒体maintenance。

## 结果与删除边界

有效建议最多0–3项，保存稳定item ID、source scope/turn/revision/exact_quote、kind/basis/explanation/suggestion；结果有review_result_v1、输入/策略绑定及hash。GET重新核对原输入、引用和结果hash，仅终态的有效结果可见；read不重放模型调用。空建议是有效no_suggestions业务结果；不可评价不调用gateway。

来源删除、输入hash/策略变化或账号禁用使任务失效，晚结果不恢复任何内容；真实调用的无正文attempt metadata可保留。当前无用户删除API，使用数据库删除/并发回归验证这些写入门，不能据此称删除产品已完成。

本轮只接后端任务与读取，不新增反馈页面。默认没有真实模型生成；供应商适配/权限/预算、完整用量与成本控制、人工语言质量抽查及正式复盘/一级重练仍需后续。

## 验证

先RED缺路由，再测创建/跨账号/CSRF/8KiB/幂等与别名、默认blocked/0次和no-evaluable；用注入gateway验证成功/0建议/非法引用、事务外调用、唯一提交、两worker竞争、旧token/过期/输入变动/禁用/删除晚结果、重启扫描、已知/未知失败及3次上限、同logical key、用量unknown和attempt metadata保留。目标与全量API/Ruff、测试库迁移降升/metadata，独立规格后质量审查；独立测试库实际HTTP验证状态到结果与默认禁用，精确清理临时身份/服务/凭证，保留开发库数据升级及更新HANDOFF。
