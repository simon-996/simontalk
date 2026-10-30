# 本人练习历史与详情（B3）

日期：2026-10-23。按已授权持续开发和基础版本路线推进，复用现有保存文字与复盘；不涉及真实供应商、删除或重练客户端。

## 体验与范围

首页增加“记录”，记录页保留“练习 / 记录 / 我的”三个可用导航。列表显示普通自由聊天或逐句重练、登记时间、原难度、练习状态和保存状态；没有真实时长/评分依据时不显示这些数值。准备取消/失败也如实保留，不计为成功练习。

每页10项，明确“上一页 / 下一页”，同时间以UUID倒序稳定排列。详情通过push进入，返回保留原页与滚动位置；刷新网址可独立读取。详情显示登记/结束时间、原难度及练习、保存、连接待核对状态。sealed才提供“查看已保存文字 / 查看复盘”；复盘仍只GET，创建建议须原页面明确操作。重练显示类型及可读取的来源详情，列表包含所有本人普通/重练记录。

空态、首次加载、刷新、网络失败、记录不存在及身份失效独立显示。翻页网络失败保留原页并说明未翻页；刷新先清旧数据。401/身份改变/404/非法响应清数据，旧账号迟到响应不可发布。每次操作总8秒，单飞、可取消，无自动重试。初次进入只GET，不开麦、不创建、不续租、不生成反馈。

## 服务端契约

新增GET `/v1/practice-history?limit=10&cursor=…` 与 `/v1/practice-history/{session_id}`，独立前缀避免现有UUID详情捕获。返回schema_version、source=server_recorded、account_id；列表含limit/items/next_cursor，详情含item。

item字段：id、kind、source_session_id、status、created_at、ended_at、difficulty（configuration.effective_difficulty快照）、completion_status（unregistered/ending/sealed）、coverage（null/pending/complete/incomplete）、connection_pending（任意连接仍占用或unknown）。不返回正文、供应商配置、目标或任务结果；sealed仅表示内容固化，不代表连接已安全终止。具体正文和有效复盘继续由原接口核对来源。

服务端限1–20项，按(created_at DESC,id DESC) seek。cursor为有界base64url JSON [account_id,UTC时间含微秒,id]；严格解析/绑定本人，无需查游标记录，删除边界记录不会破坏游标；不是授权凭证。新记录在刷新后出现，不移入后续页。无数据快照承诺，时间/ID不可变，删除记录不补回原页。非法cursor400、跨账号cursor400、跨账号详情与不存在均404。继续使用session_identity及X-Account-ID校验。

单个SQL查询只选摘要列，左连completion及关联EXISTS查询connection_pending，不加载JSON正文或逐条查询。新增(user_id,created_at,id)索引，迁移只建索引，不改历史记录。

## 实现与验证

后端独立history模块/路由，Flutter独立history模型/仓库/控制器/provider/页面/view/预览。沿用AccountFrame、主题和Riverpod作用域；有限一页用Column，不嵌套可滚动列表。测试覆盖同时间分页、账号、非法cursor、保存/unknown、纯读、索引、迟到/超时/离页、翻页保留、深链接、返回位置、320/375/横屏/深浅/200%/键盘。独立数据库真实HTTP与客户端wire验证多页、重启与零写入；实际浏览器与Preview补证。夹具证明工程路径，真实语音仍未接入。

取舍：复用现有详情不足以列出多次记录，因此增加独立摘要接口；不在列表聚合全文或重新验证全部复盘结果，避免读取历史触发生成或无界负载。删除产品流程留在B4。
