# 一级重练目标确认与独立准备客户端契约

日期：2026-10-23。沿用[后端契约](2026-10-22-rehearsal-preparation.md)、D13/D20和[交互规格](../design/2026-10-15-screen-and-interaction-spec.md)。本单元只接真实目标/独立准备登记、安全放弃及只读目标回看，不预留连接或启动媒体，不生成改善评价。

## 路由和入口

| 地址/入口 | 实际行为 |
| --- | --- |
| 普通复盘建议旁“练这一句” | 额外本人元数据GET确认ordinary后才显示；点击仅进入目标读取页 |
| `/practice/:sourceId/rehearse/:itemId` | 本人GET目标，显示完整原句/精确片段/建议/解释/安全前文；明确确认才POST独立准备 |
| 历史重练详情“查看重练目标” | 进入该子本身的固定目标，不以它为新父 |
| `/practice/:childId/rehearsal-target` | 先GET本人子元数据，再GET固定目标，核对source/item；只读，来源失效撤下目标，子历史仍独立可读 |

两条地址在账号恢复/不可达及未设难度时保留；重新确认身份后再GET。返回优先pop保持原页面和位置，无栈时回来源复盘/子详情。重练自身复盘不提供派生入口，服务器仍核验一级关系。

已完成日常难度设置者默认使用当前难度，可选择仅本次override。未设日常难度者只读目标和“去设置难度”，通过既有`/account`→`/setup`完成设置后从原复盘回来；不能用override绕过后端`preferences_required`。本页不会修改全局偏好。

## 请求和状态

`RehearsalController`绑定原账号和URL，构造/监听零请求。Screen明确首次load只GET。每操作使用独立HTTP fork，单飞，总8秒包含CSRF与子目标两次GET；多步之间及响应后核对单调截止/身份。dispose、账号变化与401清除正文并关闭本操作，迟到不能发布。

明确确认时固定刚展示的完整目标、`target_hash`、本次难度及随机key，调用原创建API。正常响应须绑定owner、source/item、独立child、目标全部字段及实际难度；不复制来源文字到新转写。默认网关不可用503如实显示未登记，不继续连接。

网络/超时/未知5xx/无法核对成功响应保持`unconfirmed`及原请求。仅明确“确认上次准备请求”才重放同key/hash/难度；此时不能改难度或刷新替换请求。确定4xx拒绝后清旧目标，须重新读取、重新确认。只在`created && epoch == 0`时说明语音尚未开启；另一设备已推进状态时提示变化并提供记录/当前练习入口。

明确放弃已知、尚无连接的准备走既有`discard-preparation`及`expected_epoch`核验。丢回复保留已知child并允许安全重试；冲突不宣称已取消。身份变化后触发上次build的旧导航按钮也会检查当前准备，不跨账号导航或空断言。

未知请求key仅保留在当前控制器生命周期内，不落磁盘。离页/刷新不自动启动写入，也不声称服务器未受理或已取消；剩余准备由首页现有current读取和明确清理处理。当前页不提供“再练一次”的媒体流程或改善评分。

## 数据与显示

严格目标模型验证schema/source/证据来源、owner/URL/普通父/item、版本/UUID/hash格式、原句包含精确引用、UTF-8/NUL和64KiB目标边界，核对前文ref结构。深度不可变，不缓存到磁盘。服务器重新验证来源和目标摘要；客户端不另实现SHA算法，而是确认原hash并逐字段比较创建回复与原目标。

680最大阅读宽度、自适应留白、主题语义色、可选择原文、原生按钮和可换行难度选项。前文区分用户与AI已报告播放片段，建议句不能当作已说转写。浅/深320/200%字、横向、未知及未就绪均有组件检查，独立Preview样例不导入正式页面。

[验证报告](../development/2026-10-23-rehearsal-client-verification.md)区分实际HTTP、Dart wire、组件渲染与浏览器待补；普通详情关联列表已由[后续单元](2026-10-23-related-rehearsals.md)接通；真实语音/改善评价及实际设备仍待后续。

## 点击时复验（2026-10-24）

Screen在实际点击时核对当前Route与最新URI、已登录owner、账号非busy、当前provider/controller及控制器非busy。明确准备绑定实际展示target对象和难度，后续选难度或重读目标后旧确认不提交；原请求核对绑定同一目标，仍由原Controller重放原key/body；放弃和查看记录绑定展示preparation。刷新、难度、当前练习和设置入口也遵守同一门。

返回核对当前页面、账号非busy及当前owner/provider/controller，但保留控制器请求期间正常离页的既有契约；离页不宣称未受理或已取消。账号操作中保留已读内容并禁用操作/返回，单独显示账号提示；只在真实请求时显示进度。未连接页旧恢复先校验mounted/当前页面及仍不可达且非busy，销毁后不读WidgetRef。见[验证](../development/2026-10-24-rehearsal-action-guards-verification.md)。

## 实时重练通话交接（2026-11-25）

当非只读目标页已完成独立准备登记（`RehearsalState.prepared`、`status == created`、`connection_epoch == 0`）时，`RehearsalView` 提供“进入重练通话”。点击时复验当前路由、登录账号、非 busy 及展示的 `target` 与 `preparation` 引用一致，构造不可变的 `RehearsalSessionLaunch`（核验账号、一级重练 `kind == 'rehearsal'`、来源普通练习与建议项 ID 匹配），经路由 `extra` 进入 `/practice/session`；浏览器刷新丢失 `extra` 或账号不一致时，路由守卫重定向回 `/practice`（未登录回 `/login`），不会误开麦克风或新建普通练习。

`PracticeSessionScreen` 在收到 `RehearsalSessionLaunch` 时调用 `PracticeMediaController.begin(preparation: ...)` 直接在该重练记录上预留连接，不额外创建或取消普通练习；通话中显式展示“重练：这一句表达”、本次覆盖难度及关注片段/参考说法，结束后提供“查看重练评价”（已封存时进入 `/practice/:childId/review?from=history`）、“查看本次记录”、“回原复盘”（固定回来源普通练习）、“再练一次”（失效旧重练控制器并回到同来源同建议项重新确认新同级重练）及“回到练习”。详见[一级重练实时语音验证](../development/2026-11-25-rehearsal-live-voice-verification.md)。
