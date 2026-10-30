# 持久反馈任务与有效结果验证

日期：2026-10-21（Asia/Shanghai）。实施依据[设计](../superpowers/specs/2026-10-21-review-jobs-design.md)、[计划](../superpowers/plans/2026-10-21-review-jobs.md)与[实际接口契约](../architecture/2026-10-21-review-jobs.md)。在原功能分支保留全部既有未提交工作；只改后端及文档，没有真实模型调用、新页面、原生构建、提交、推送或部署。

## 1. 实现与边界

新增ReviewJob/ReviewAttempt/ReviewAction/ReviewResult及迁移8b2731f5ca90，绑定原ReviewInput四项依据和固定review_generation_v1。本人POST创建/重试、GET纯读；动作key精确绑定操作、路径及body，不同key复用同输入任务也记录映射。新key不能重置次数或绕过未知调用门。

任务采用短事务领取、调用前独立短事务复验、事务外gateway、短事务fenced提交。15秒原lease不延长，gateway最多8秒，有限2/8秒退避及合计3次调度。来源与原话核验后再次检查lease，任一项非法整批不落正文。有效结果固定版本1、稳定item UUID/ordinal及hash；读取重核原输入/quote/hash。独立ReviewJobRunner周期扫描持久队列与过期running，候选之间及外调前响应stop；两个runner分别停止并释放池。

默认Unavailable：正常输入blocked/capability_unavailable且0次；不可评价为no_evaluable_content且不调用。超时、未知异常、过期running保留outcome_unknown；无经验证幂等能力时不自动或手动再次调用，有能力才复用固定logical key有限重试。未知用量为null，attempt无prompt、原话、原始响应或异常正文；练习删除清正文/任务，attempt关联置null保留元数据。当前无用户删除HTTP、供应商适配、完整计费或费用封顶。

## 2. 自动化与独立复核

先观察缺路由404而期望202的RED，再实施。新增44项回归，目标最终44通过；根任务在全部修复后独立运行：

| 检查 | 实际结果 |
| --- | --- |
| `uv run --locked --no-sync pytest`，API全量 | **506通过，106.94秒**；前批462，新增44 |
| `uv run --locked --no-sync ruff check .` | 通过 |
| `uv run --locked --no-sync ruff format --check .` | 73个Python文件已格式化 |
| 测试库Alembic降4c913f2d8e71→升head | 通过，最终8b2731f5ca90 |
| 测试库及开发库`alembic check` | 均无新升级操作，metadata一致 |
| 独立规格及质量复审 | 均通过；最后补修再做规格复核通过 |
| 文档链接/锚点/围栏及工作区空白 | 34份变更Markdown、290处本地链接/锚点通过；git diff --check通过 |

覆盖本人/CSRF/账号头及锁等待后会话撤销复验、请求8KiB门、动作精确重放与别名/冲突、同输入并发创建、GET无副作用、默认零调用与不可评价。执行测试覆盖安全payload、gateway等待期间可取User锁、两worker唯一领取、过期lease/旧fence、固定配置与幂等标志、未知/已知失败、三次上限、固定logical key、重启扫描及停止。结果测试覆盖非结构输出/假quote整批拒绝、空建议、稳定来源与hash复核、nullable真实报告用量，以及删除/禁用/来源变化的晚回写和无正文attempt保留。

独立审查发现并先补RED后修复五项：校验耗时跨lease仍提交；dispatch未固定幂等标志；候选读缺SQL边界且关闭异常跳过maintenance；领取后失效仍外调；候选循环未响应stop。对应回归覆盖来源/error和quote/success两种跨lease、同ID/不同幂等标志、候选表锁、关闭异常、外调前过期/删除/禁用/hash变化/旧token/复验耗时跨lease，以及候选之间和claim后停止。最后质量审查另独立运行相关11文件Ruff与格式检查，通过；审查agent没有运行数据库测试或服务。

## 3. 最终代码的实际HTTP与后台扫描

使用127.0.0.1:8001临时API、独立simontalk_test及显式fixture gateway。三个临时身份均经实际注册/偏好/准备/连接/文字/end/manifest/review-input接口建立来源；A/C各一句最终用户文字，B为空。语音准入仅测试注入，没有调用供应商或声称语言建议正确。

| 身份/场景 | 实际观察 |
| --- | --- |
| A默认配置 | 创建202 blocked、0次；同key重放及不同key别名均为同job；同key变body409 idempotency_conflict |
| B空输入 | no_evaluable_content、0次、result=null；全程未调用gateway |
| A显式重试，测试能力可用 | 独立runner领取→succeeded，1次、1个经精确引用校验的item；多次GET结果与item/hash一致 |
| A重放创建及重试key | 返回当前同job，不增加调用 |
| C测试非法quote | failed/invalid_output，1次，result=null；未经校验正文不存 |
| C明确重试，测试空建议 | no_suggestions，累计2次，items=[]且有效版本/hash；重放不再调用 |
| B读A任务 | 404，本人隔离；所有检查响应no-store |

最终恰3次fixture调用，C的两次复用同logical key；数据库实际3个job、3个attempt、6个action、2份结果。后一次完整HTTP在质量补修后的最终代码执行并通过。测试账号/邀请及其关联数据精确清除；临时API关闭，脚本、控制文件、计数文件及字节码清理；后一次凭证仅在进程内存中，没有写磁盘。保留的本地验证日志不含凭证或生成正文。

## 4. 开发库、服务与工作区

先与本轮开始保存的revision/13张表数量比对，确认开发库仍4c913f2d8e71且全部数量一致；随后升级8b2731f5ca90并再次核对。原1用户、1邀请、11会话、1偏好保留，其余原练习/连接/观测/文字/播放/固化/核验/复盘输入均0；新增4张反馈表均0。默认开发库没有写测试练习或反馈。

默认API8000用最终代码重启，live/ready均200；新review端口未登录401/no-store，准入、信令及反馈gateway均为Unavailable。锁文件未变，既有客户端和此前后端工作保留；本轮没有Dart/UI变更，不重跑无关Flutter/Node/Web构建，前批客户端证据仍为其原时点。

## 5. 尚未验证与下一步

本轮证明持久调度、状态、引用/来源门及结果存取，不能证明识别准确、语言反馈质量、真实上游幂等或终止、实际设备体验与费用上限。数据库复验与外部调用间仍有不可原子的跨系统窗口；已领取未外调遇停止时保留running/unknown供租约恢复，不编造已取消或零用量。

下一单元接入客户端严格模型和原账号任务请求、纯读/明确重试及真实状态；正式复盘、一级重练、完整历史/删除产品与用量控制继续分组实施。供应商账号、地域、预算与设备输入继续暂缓，默认模型保持关闭。
