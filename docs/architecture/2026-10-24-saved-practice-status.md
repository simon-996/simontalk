# 每次练习的保存情况读取

2026-10-24，已接入基础版本B2保存结果/B3历史回看。设计见[保存结果页](../superpowers/specs/2026-10-24-saved-practice-status-design.md)，[实际验证](../development/2026-10-24-saved-practice-status-verification.md)。

历史详情的“查看保存情况”进入`/practice/:sessionId/save-status`；该路径为本人只读地址，账号恢复/不可达保留，未选难度仍可查看。返回沿实际栈，直达时回该练习历史详情；地址无效回历史列表。文字与反馈入口继续使用原详情。

独立SavedPracticeStatusController复用两个已存在仓库：GET `/v1/practice-history/{sid}`核验本人及历史摘要；随后GET `/v1/practice-sessions/{sid}/completion`严格核验原结束scope、状态、固定截止、封存版本与缺口。两次GET共8秒，单飞、独立原账号HTTP fork；每步前后与发布前检查账号/截止。只有历史status/coverage与completion一致才整体发布；不一致为save_status_changed，由本人明确刷新。历史unregistered且第二步明确404 completion_not_found才显示未登记；其余404不可假报未登记或保存成功。

构造provider不读取。初读/刷新先清旧快照；网络/响应异常、删除/来源失效不继续显示旧成功；dispose和账号变化取消进行中读取，晚到结果不能发布。页面刷新在激活时复验当前路由、controller、owner与busy；账号busy只禁用操作并提示账号操作，不冒充实际保存读取。返回允许取消正在读取的页面。

复用PracticeSaveStatusView呈现保存阶段与具体缺口。连接提示采用历史整次connection_pending聚合，未采用origin单连接推断全部连接；无pending时仍说明实际用量另核对。内容已保存不代表停止计费。本页不结束练习、不重放上传、不调用生成、不开麦；保存补交与终止核验继续由既有账号/媒体作用域负责。

可信删除凭据后失效savedPracticeStatusProvider family（纯读），包括 retained reader与进行中GET。失败、结果未确认或保留不触发成功清理。此family无创建key、媒体和补交队列，不改变既有生命周期。

此模块提供每次练习的服务器保存结果；正式通话/正常结束上传控制、真实模型/用量、实际浏览器/设备仍按基础路线验收，不能据此标B2/B6完成。
