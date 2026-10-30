# 原账号复盘任务客户端契约

日期：2026-10-21。依据[设计](../superpowers/specs/2026-10-21-review-client-design.md)及[后端任务](2026-10-21-review-jobs.md)、[复盘输入](2026-10-21-review-inputs.md)。实施与运行证据见[验证报告](../development/2026-10-21-review-client-verification.md)。本单元提供Dart请求/状态能力，正式页面和媒体链另接；默认模型Unavailable。

## 1. 原封存输入与解析

`ReviewTarget.fromCompletion`只接受已严格解析的sealed PracticeCompletionSummary，固定原account/session、input_revision=1与practice input hash。ending、缺hash或跨账号不能用于生成。复盘属于整个封存练习，不以当前连接覆盖原input，也不从页面任意字符串拼装来源。

ReviewInputBinding只留存服务器响应的绑定、数量、业务态和时间摘要，不留scopes原话或安全前文。它核对原账号/练习/版本/hash与review_input_v1，不声称重新计算资格；ready须有eligible或uncertain，no_evaluable_content不能被当技术失败。响应512KiB、32scope/8192决定上限沿用服务端。

ReviewJobSnapshot核对四输入绑定、review_generation_v1、job身份、次数、时间及状态字段；ReviewResult/Item核对schema/version、同job/输入、唯一稳定item ID/连续ordinal、类型/依据、正文长度与不可变集合。succeeded有1–3项；no_suggestions有有效空结果；no_evaluable_content为0次且无结果；其他状态无结果。hash校验格式及前后身份一致性，精确原话与结果摘要的权威验证仍在后端，不冒充客户端验签或语言质量认证。

## 2. 本人仓库与明确动作

ReviewRepository沿用ApiClient原账号头、Web Cookie/CSRF或移动Bearer；所有端口显式accountId。createInput/readInput/createJob/readJob/retryJob分别对应实际API；输入写只带原版本/hash，创建任务带四绑定，重试带job_id/expected_attempts及动作UUID。响应解析错误统一invalid_response，不把非法或他人结果带入状态。

| 客户端操作 | 行为 |
| --- | --- |
| requestReview | 明确创建ReviewInput后请求唯一任务；动作开始时固定key并沿用到输入/任务两阶段，任务body绑定确认后的原输入 |
| refresh | 仅GET input→GET job；缺输入/任务表示尚未创建，不隐式POST/生成/重试 |
| retryGeneration | 只有已读blocked/failed、次数未满3且outcome_unknown=false才可建立新动作，固定原job/expected_attempts |
| retryPending | 明确重放不确定操作的原key/body；不会将网络重试变成新的模型重试 |

单飞串行，重复点击不排队第二个写入。排队、运行、退避、成功、正常空结果、失效、次数耗尽及未知调用结果均不能通过客户端操作另建生成尝试。客户端保守门不替代服务端最终权限/次数/幂等裁决。

## 3. 刷新、失败与身份

每个操作以独立HTTP client/fork执行，多请求和CSRF共用总8秒期限，步骤之间检查原账号与剩余时间；完成、超时、取消和dispose关闭所属HTTP。没有自动轮询或页面重进自动生成。

刷新开始撤下旧显示内容；网络/CSRF失败后保留待确认动作，用户可明确重放。确定409 review_retry_changed或idempotency_conflict清除未按该请求受理的动作，先纯读当前状态再明确建立允许的新动作，不自动换key重发。404 review_input_not_found/review_job_not_found不伪造成功空反馈。401、account_changed、来源删除/失效或输入不符使旧客户端终止并清理动作与正文；普通断网不清登录。换账号后getter即清旧数据，不等待provider销毁，晚到结果不得发布或触发后续请求。

输入hash、job ID、最大已知次数和成功结果hash/item IDs作为无正文锚点；刷新撤下内容时保留这些锚点，禁止换输入/job、降次数或悄悄改写成功结果。读取缺失和技术失败分别表达，不能把过时成功继续显示成当前读取成功。

## 4. 作用域与当前边界

账号autoDispose family仅在signedIn且target属于当前账号时提供client，跟随原ApiClient并在销毁时清理。构造与监听零HTTP；页面离开不无限保活反馈正文，服务器任务仍持久存在，后续可明确纯读恢复。Web不写浏览器持久存储，移动端也不新增正文持久层。

本能力不控制麦克风、建连、占用、终止核验或用量，不改变只读恢复面板。尚无正式复盘/一级重练页面、真实模型语言质量、完整历史/删除或成本准入；测试fixture和API运行证据须分别标明。
