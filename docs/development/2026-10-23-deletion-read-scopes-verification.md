# 删除确认后的本地读取清理验证

日期：2026-10-23。持续开发授权内，按[计划与方案](../superpowers/plans/2026-10-23-deletion-read-scopes.md)修补跨入口遗漏。沿用[本人删除契约](../architecture/2026-10-23-practice-deletion.md)，后端/schema/依赖均未改变。

## 复现与修补

原删除成功清理点会失效history/review/transcript，但遗漏恢复读取和后续新增的重练目标、ordinary资格、关联列表。通过真实Riverpod订阅保留这些scope后，确认删除并回到历史，旧RehearsalController仍能返回目标正文；在途目标/列表/恢复GET的晚回复也会再次发布旧内容。这里验证的是仍被订阅的本地scope，不将其夸大成已证实的服务器越权或跨设备删除通知。

在既有可信凭据清理点补四个provider失效：practiceRecoveryProvider、rehearsalProvider、rehearsalEligibilityProvider、rehearsalListProvider。旧实例dispose清内容并取消独立HTTP，晚到不能再发布；新读取控制器构造静默，仍被订阅的资格FutureProvider可重新GET核验。保留记录、409范围冲突和删除结果尚未确认不会提前触发成功清理；未知结果明确核对原凭据成功后才清。

恢复、列表为只读；rehearsalProvider也保存创建/原key动作，不能称作纯读缓存。全family失效会结束其本地目标和未确认key，与成功go('/history')本来关闭RehearsalScreen及key仅存当前控制器的现有契约一致；不保证额外长期订阅中的无关创建动作继续保留，也不自动重放或另建。未结束准备仍由current恢复核对。Entry、Preparation、Media provider不失效，不以dispose代替可信终止或恢复原请求。

删除后重新读current仍为content_deleted和unknown，提示连接/用量待核对。本单元没有新增取消准备/连接、续租、媒体、生成或重放请求，不把清正文当作停止费用。

## 实际检查

| 检查 | 结果 |
| --- | --- |
| 原历史/重练/恢复基线 | 205通过，约7秒；排除已新增的首个复现用例，不将其混入原基线 |
| RED | 删除页17项中12通过/5失败；旧目标、late target/list/recovery及原key凭据核对成功后的清理分别失败 |
| 修补后删除页 | 17通过，约1秒，新增7项常规回归 |
| 目标回归 | 212通过，约6秒 |
| Flutter全量 | **1016通过，9项专用夹具默认skip，约32秒** |
| 分析/格式 | 两处测试if补括号后，无问题/1.9秒；206 Dart文件格式符合 |
| Node | 58通过，含真实Dart编译桥接 |
| Web/字体 | release32.9秒；30,890完整映射、7,782,072字节WOFF2及本地Roboto核对通过 |
| 独立只读复核 | 未发现确定的当前产品回归；特别指出并在上文明确rehearsal family的生命周期范围 |

7项新增覆盖：同时保留四类scope的成功清理及unknown恢复；三类在途读取的晚到；保留/409不清；已受理丢回复时先保持、明确凭据核对后清且只有一次DELETE。读取和控制器/provider/路由均为实际模块，HTTP响应由测试替身控制，以确定复现时序。测试只证明这些本地行为，没有启动API、访问数据库或调用真实网关；本轮没有新增实际wire，不把9项skip算互通成功，也不把历史API709重标为本轮结果。

## 浏览器与保留

本轮工具浏览器列表为空，仍返回`Local browser use is disabled in Work settings`；原生表面另报Mac锁屏。未请求解锁、未创建标签或启动Web/Preview服务，实际浏览器Cookie/点击/辅助技术继续待补。没有新布局、文字或Preview样例，不重新生成截图，不将旧截图记为本轮证据。

开工616个文件均保留，仅预期客户端及文档变化；100个后端文件及两端4个依赖/锁文件摘要不变。[文件保留核对](evidence/2026-10-23-deletion-read-scopes-preservation.json)。数据库未访问、未迁移、未写入，无API或测试库/凭证新增；原分支和既有改动保留，未提交/推送/部署，无模型或原生构建。

本单元完成删除后的本地scope衔接修补。真实语音、改善评价、实际浏览器/设备及完整基础版本验收仍待后续。
