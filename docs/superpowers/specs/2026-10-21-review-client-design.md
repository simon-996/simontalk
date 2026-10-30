# 原账号复盘任务客户端

日期：2026-10-21。承接[后端任务契约](../../architecture/2026-10-21-review-jobs.md)和[输入契约](../../architecture/2026-10-21-review-inputs.md)。持续工程授权允许本地开发及可逆选择，不提交/推送/部署、调用供应商或恢复原生。现有dirty全部保留。

## 范围与选择

本单元实现可接正式页面的Dart模型、本人仓库、状态客户端和账号作用域provider，并通过真实HTTP验证。当前恢复控制器已包含多类只读来源；将复盘写入塞入它会混合恢复与新生成权限。采用独立`features/review/`，复用ApiClient账号/CSRF/取消机制；直接页面中发请求则无法集中保存不确定请求的固定key/body，不采用。当前不改既有页面或媒体链，不自动生成、定时轮询或展示夹具反馈；正式复盘页面另做。

## 模型与信任边界

ReviewTarget仅由严格解析过的PracticeCompletionSummary建立，要求sealed、input_revision=1及64位小写hash，绑定原account/session。拒绝ending和跨账号，不从UI传任意hash拼装目标。目标值相等供provider family稳定复用。

ReviewInputBinding解析服务器派生的摘要：source/evidence_source、原账号/练习/版本/hash、固定review_input_v1、review_input_hash、created_at、ready/no_evaluable_content及三类counts。只留存摘要，不保留scopes中的原话/安全前文；不得声称客户端重新派生资格。响应必须在服务器512KiB展开上限内，scope≤32、总决定≤8192，计数与业务态一致。POST body仅原input_revision/input_hash；任务body使用确切四绑定。

ReviewJobSnapshot/ReviewResult/ReviewItem严格解析身份、四绑定、review_generation_v1、9种实际状态、attempt_count 0–3、布尔、UTC日期、nullable next/error/result及状态之间的约束。结果schema=review_result_v1/version=1、job与输入绑定一致；succeeded须1–3项，no_suggestions须空有效结果，no_evaluable_content须0次且无结果，其余无结果。item UUID唯一、ordinal从1连续，source UUID/严格revision、精确非空quote≤8192字符、explanation≤4096、suggestion≤8192，kind及basis为契约枚举，不接受发音项。集合不可变。hash只校验格式与既有身份/结果一致性，原话/结果摘要的权威校验仍由服务器执行；不引入依赖或冒充客户端密码学验签。

## 请求与状态协调

独立ReviewRepository明确提供createInput/readInput/createJob/readJob/retryJob，全部显式原accountId，捕获FormatException转invalid_response；写入key必须UUID。构造/读取/provider监听不发HTTP。

PracticeReviewClient提供requestReview、refresh、retryGeneration、retryPending。requestReview明确创建输入再创建任务，开始动作时即固定UUID，输入与任务两个阶段沿用同一动作key（输入端口不建立后端Action映射）；输入未确认时重试仍用原seal，任务请求固定原四绑定/key。retryGeneration只在已读blocked/failed、次数<3、outcome_unknown=false时建立新动作，body固定job_id/expected_attempts；排队/运行/退避/成功/空建议/不可评价/失效或未知调用不另发生成请求。服务器仍为是否可调用的最终门。

网络异常或响应不可确认后保留原操作、key与body，retryPending只明确重放这一动作；重复点击单飞，不生成新key/排队第二次写。确定HTTP409 review_retry_changed或idempotency_conflict说明动作未按此请求受理，清除该待确认动作并保持失败/无旧显示；先纯读当前状态，再由用户明确发起允许的新动作，不能自动换key重发。refresh始终GET input再GET job，404 review_input_not_found或review_job_not_found表示尚未创建，不变成空反馈，不隐式POST或丢掉待确认动作。读取和写入操作均总计最多8秒（含CSRF/多请求），每次独立HTTP client/fork，步骤之间检查时间/账号；完成、超时、取消和dispose均关闭所属连接。

刷新开始即撤下旧显示结果，失败不展示旧成功；待确认动作可继续精确重放。成功的输入hash、job_id、最大已知次数及成功结果hash/item IDs作为无正文锚点，后续响应不能降次数、换job/输入或改写成功结果。401、account_changed、来源删除/失效及输入不匹配清空正文/动作并关闭客户端；一般网络/CSRF问题不抹去登录，允许明确重试。账号切换后即使旧请求晚到或provider尚未销毁，getter也不得露出旧结果；任何不可变快照的消费者仍须随账号清理。

## Provider与平台

账号作用域autoDispose family只在signedIn且target属于当前账号时提供client，跟随原ApiClient，dispose清理；外层监听client变化，创建/监听无HTTP。页面离开不保活正文或无限轮询；服务器持久任务继续，回来可显式纯读恢复。Web不写LocalStorage/IndexedDB/文件，不存凭证或反馈副本，移动端本单元同样不新增持久层。客户端不控制媒体、占用、供应商终止或用量，不改PracticeMaintenance/ReviewJobRunner。

## 验证与交接

先RED再实现：严格目标/绑定、状态/结果/非法枚举/日期/布尔/不可变集合，仓库身份/路径/body/key，客户端单飞/固定重放/GET零写/多步骤总截止/CSRF/账号改变/销毁晚到/404与来源失效、无正文锚点及保守生成门；provider账号隔离与无隐式请求。独立规格后质量审查，再根任务完整Flutter、analyze/format、Node/Web/字体与实际HTTP。后端未改不重跑全量API，但检查默认健康与开发库数据未被夹具污染。实际HTTP只用独立测试库与显式fixture gateway，验证blocked/0次、有效/空建议/非法quote、明确重放及隔离，测试API/账号/邀请/凭证清理。更新HANDOFF、架构/集中契约/技术/路线/验证/localdev，现有历史证据保留原时点。
