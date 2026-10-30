# 恢复入口的保存与连接核验状态

日期：2026-10-21。依据用户持续开发授权、现有[交互规格](../../design/2026-10-15-screen-and-interaction-spec.md)、[视觉规范](../../design/2026-10-15-visual-design-spec.md)和[结束固化契约](../../architecture/2026-10-21-practice-finalization.md)。沿用偏好页真实只读恢复入口，不新增练习或历史占位页面。

## 选择与范围

采用用户明确点击的独立“查看保存状态/刷新保存状态”分区。相比每次查看current自动串读，它避免隐式请求及无关失败覆盖已有文字；相比新建独立保存页，它能在现有真实入口直接查看结束固化与unknown占用。只有明确的准备清理仍可写，新增查看/刷新均为GET，不开麦、不调用模型、不发end/manifest/续租/终止请求。

显示现有全局completion摘要，不展示原始event ID、hash、epoch、候选资格或技术错误码。ending显示“正在保存本次记录”、等待封存结果及真实固定接收截止；截止后可能暂留ending，不声称仍在接收；sealed complete显示“记录已保存”；sealed incomplete显示“已有内容已保存，仍有缺口”，按实际gap_codes合并为可理解原因。sealed说明已结束接收新内容，刷新不能补回未收到片段。无completion的准确404是“尚未登记结束保存”，不当作空固化或网络失败。

连接结果独立显示。unknown表示尚无可信结束，不根据completed/本地关闭推断终止或费用。只有实际blocked核验记录才显示“自动核验暂不可用，需要维护者协助确认”；not_requested只说明未有核验登记，不能冒充已在自动处理中。没有费用数据不声称已结算、零费用或已停止收费。未确认终止不提供新建/恢复按钮。

## 服务端只读接口

新增`GET /v1/practice-sessions/{sid}/connections/{cid}/termination-check`。本人鉴权，沿用X-Account-ID、no-store和固定错误规则；原连接不存在/他账号404，不创建任务、不修改租约或状态、不调用供应商。单SQL原连接left join TerminationCheck取得一致结果，返回：

`source=server_recorded, account_id, session_id, connection_id, client_instance_id, epoch, status(not_requested|blocked), reason, attempts, created_at`。

无任务时reason/created_at=null、attempts=0；blocked时reason=capability_unavailable、attempts=0、created_at为带时区时间。不得返回attempt_digest、供应商标识、正文或凭证。当前只有blocked状态，不增加成功终止执行器或迁移。

客户端新增严格TerminationCheckSnapshot模型和仓库GET方法，核对原scope/UUID/整数/状态关系/时区。已有PracticeCompletionSummary支持未知end_key的只读验证，原loadPracticeCompletion保持严格scope。current可能返回较旧占用连接；新loadRecoveryCompletion核对最新practice.connectionEpoch，只有历史查询分支额外GET实际origin连接并独立核对account/session/client/epoch，再解析全局摘要。termination-check始终读取current原占用连接，不套用origin。

## 控制器和页面

PracticeRecoveryController新增独立读取操作。仅已有原connection时可开始；与已有读取/清理串行，一个8秒总截止涵盖completion、必要的origin连接核对和termination GET；每次追加HTTP前复核账号及单调截止，过期不开始下一请求。completion_not_found只在准确404时变未登记；其他错误照常处理。两结果都核验成功后原子发布，失败不把部分结果显示成已核对。显式刷新先清旧保存状态；账号401/409、本地账号变化、删除/连接不存在、总刷新和dispose清掉旧摘要/核验记录，晚响应不能恢复。网络失败保留登录，提供明确读取重试，无自动轮询或写入。任一读取（包括观测）确认父练习/连接不存在均清除全部状态。有效completion已确认登记结束后，保留无正文endRegistered门；即便第二GET或后续局部刷新失败，也不重新放行旧current的准备清理。该门随总current刷新、身份变化、404和销毁清除，不保留旧摘要供失败显示。

新增无副作用PracticeSaveStatusView，接入原恢复View的文字分区之前。独立加载/未查询/未登记/ending/完整/不完整/失败状态，按钮在busy时禁用，状态用文字和liveRegion说明，不仅靠颜色。gap_codes分组：文字缺失/拒收；输出证据缺失/撤销；未final或尾部不确认；提前中断；缺清单及范围核对不一致。不得把序号跳号说成丢字，不把AI生成内容当已听见，不把封存冲突变成无限保存重试。

completed仍有unknown占用时标题可为“上次练习状态”，业务标签改为“练习已结束”，避免“已完成”被理解为真实语音/学习闭环完成。其余现有空态、文字选择/独立滚动、观测分页、准备清理和身份恢复继续有效。入口仅覆盖current返回的练习/占用连接；已安全结束且current为空的完整历史仍未实现。

## 布局与验证

沿用语义主题/Material按钮、现有分区留白和680可读宽度，不再嵌套装饰卡片。小宽度与200%字号自然换行，操作保持44/48以上触达目标；键盘焦点可见，长状态可滚动，文本不截断。用Flutter Preview深浅色320及大字号预览，另跑实际Web页面/浏览器核对状态、刷新失败及账号隔离。

先写API只读/隔离和客户端严格解析、控制器串行/总截止/清除、widget语义/加载/缺口/窄屏回归并观察失败，再实现；独立规格和质量复核。验证真实HTTP与浏览器使用独立测试库/临时账号及测试准入，供应商保持关闭，清理临时服务/凭证/数据。全量Flutter/API/Node、分析/格式、Web及字体通过后更新HANDOFF与实测报告，保留全部既有工作，不推送部署，原生暂停。
