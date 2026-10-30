# 来源练习的关联重练列表

2026-10-23，沿用[一级重练后端契约](2026-10-22-rehearsal-preparation.md)和[目标确认客户端](2026-10-23-rehearsal-client.md)。本单元只有Flutter及其验证、文档变化，后端/schema/依赖不变。[设计](../superpowers/specs/2026-10-23-related-rehearsals-design.md)、[计划](../superpowers/plans/2026-10-23-related-rehearsals.md)、[实际验证](../development/2026-10-23-related-rehearsals-verification.md)。

## 页面与返回

普通本人历史详情提供“查看关联重练”，打开`/history/:sourceId/rehearsals`；子详情不提供此入口，服务端仍核验ordinary。恢复账号或连接不可达时保留地址，未设日常难度也允许读取。首次只GET，构造/监听不发请求，没有自动轮询或写入。

每页最多10条，只显示服务端记录的登记时间、结束登记时间和练习状态。列表没有难度、保存完整性、时长或改善成绩字段，不从状态推算这些信息。每条进入原历史详情，沿既有入口查看已保存内容、复盘或目标。来源反馈失效不会阻止同级元数据读取；子目标仍受其原有效性门约束。

上一页/下一页显式读取；成功后将键盘焦点和滚动带回当前页标题，Tab仍可继续。返回子详情保留原列表页与滚动，不自动刷新。列表返回优先pop，无栈时回来源历史详情。

## 严格读取与生命周期

`RehearsalListRepository`仅调用`GET /v1/practice-sessions/:sourceId/rehearsals?limit=10`，后续页带`before_id`。模型验证schema/source/owner/parent/limit、32KiB上限、逐项一级关系与UUID、严格UTC日期和结束不早于登记。当前页不可变、无重复、按`created_at,id`严格倒序；非空下一游标只能是满页末项。

控制器保存已确认页的前置锚点，含时间和ID。每一后续项必须比本地锚点更旧，不能只信服务端游标。上一页重新读取其原前置锚，成功后丢弃旧的后续锚；重新前进按新页末项读取。记录增删可能改变页内容，页码不承诺稳定总数。

每次用独立owner-bound HTTP fork，单飞，总8秒，响应后再核对单调截止。dispose/账号变化关闭本操作并清旧，迟到不发布；旧行回调重新检查账号、当前页成员和busy，避免旧页面跨账号导航。

翻页网络/超时/限流等暂时失败保留原页、页码和明确重试。刷新先撤旧回第一页。401、来源404/409、游标404或非法响应清空页和分页锚；游标被删须刷新，不自动改为第一页冒充原翻页成功。401或账号变化要求重新确认身份。

## 证据边界

浅深主题、320宽/200%字、横向、焦点及返回有widget检查；四态Preview样例与正式数据隔离。实际HTTP/Dart wire另验21条同时间记录的三页、回退、账号隔离、删除游标及来源；纯GET前后20业务表全行不变。真实媒体和改善评价尚未接入，组件图不等于实际浏览器验收，详见验证报告。

## 阅读操作资格（2026-10-24）

点击时复验当前Route与最新URI、已登录owner、账号非busy、当前provider/controller及控制器非busy。翻页/原话定位/记录行绑定本次展示page，旧回调不能作用于随后读取的新页，即使新页包含同一ID。刷新仍纯读。返回检查当前页面/owner/provider和账号busy，但允许真实读取期间离页。账号操作提示与实际读取分开，保留已读页并禁用动作。

未连接旧恢复先检查mounted和当前路由，再读当前账号；只在仍不可达且非busy时恢复。关联列表异步翻页完成及post-frame聚焦再次核对当前页面/owner/provider及accepted page，覆盖或离页后不抢焦点。Controller/Repository/分页与总8秒协议未改。见[验证](../development/2026-10-24-reading-action-guards-verification.md)。
