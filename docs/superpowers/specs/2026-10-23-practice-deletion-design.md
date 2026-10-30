# 本人练习删除设计

日期：2026-10-23。按基础路线B4、D13/D20和持续开发授权推进；本单元实现正式历史详情中的删除，不调用模型或供应商。

## 范围与方案

普通练习删除自身及所有可见一级重练；单删重练不影响来源/同级。先GET范围（数量、类型、范围hash、连接待核对），确认后DELETE带范围hash与固定Idempotency-Key。锁当前用户，再锁完整成员并重新计算hash，成员变化返回409，要求重新读取/确认。GET不写入。

采用内容清除加最小墓碑。直接级联删除PracticeSession会误删未知连接证据；只隐藏不清正文又不能满足删除，因此墓碑保留ID/关系/请求摘要和必要安全状态，原文字、播放正文、固化快照、复盘输入/任务/结果/动作及重练目标原子清除。已发生ReviewAttempt保留无正文的用量/未知结果记录，晚到结果不得重新生成内容。创建key不会在删除后复活旧练习。

未知上游连接变为unknown，保留终止证据并登记现有blocked核验，不声称远端已停；未开始信令的连接可安全关闭。墓碑终结业务状态，但占用独立保留，current仍展示最小待核对状态，禁用正文/复盘/开新连接。为兼容原恢复结构，仅占用墓碑保留严格白名单的无正文偏好/供应商配置，安全结束墓碑清空配置；不保留任意JSON字段。真实供应商核验仍不可用。

## HTTP

- GET `/v1/practice-history/{sid}/deletion-scope` → `practice_deletion_scope_v1/source/server_recorded/account_id/session_id/kind/record_count/rehearsal_count/scope_version/connection_pending`。
- DELETE `/v1/practice-history/{sid}`，body `{scope_version}` + Idempotency-Key → 200 `practice_deletion_receipt_v1`、owner/session/key、数量、scope_version、deleted_at、connection_pending。同步内容清除完成后返回，不以202假装仍待清除。
- GET `/v1/practice-history/{sid}/deletion?key=...` → 同本人原凭据；缺失404，不能将404凭据误认为删除成功。
- 同key/同body重放原凭据；不同target/body冲突409。跨账号/不存在404，X-Account-ID、Origin/CSRF沿用原规则。无记录ID列表/原句放进凭据。

## Flutter

独立删除页从详情进入，读取范围后显示明确影响数量与不可恢复说明。默认焦点“保留记录”，明确确认才DELETE；取消与初进零写入。完成后撤销旧历史providers、回列表并真实刷新，不显示已删除原详情。离页/身份变化取消本地请求，服务端可能已受理则结果未知，不能显示成功。

每操作8秒（包含CSRF），独立fork、单飞及迟到/账号门。写超时保留原key/body，可GET核对原凭据，凭据未找到后仅明确确认原请求才重放，不生成新key。409范围变化须重新读范围并再次确认，禁止自动扩大范围。旧详情/文字/复盘明确读取返回404；其他页面已下载的正文需刷新或重进才能获知远端删除，当前不承诺推送失效。

沿用Flutter主题、响应式、可滚动布局和大字号；预览夹具与真实来源分离。实际浏览器工具禁用时保留点击验收待办。

## 验证标准

真实PostgreSQL/TestClient验证A/B、零写scope、父/单子、范围增删/并发锁、全部正文清除、queued/running晚到、重复与丢回包核对、unknown占用不解除/安全准备关闭、所有读取与上传404。Flutter严格模型、状态/超时/CSRF、账号/离页、确认/取消/范围变化/结果未知、返回列表与窄屏大字。独立库真实HTTP与Dart wire验证，开发账号零假练习；备份恢复后重放删除仍属后续集中演练。
