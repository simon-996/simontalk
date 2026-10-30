# 删除页点击资格与可见范围验证

日期：2026-10-24。持续开发授权内，按[计划](../superpowers/plans/2026-10-24-deletion-action-guards.md)修补基础版本B4删除操作。沿用既有[删除契约](../architecture/2026-10-23-practice-deletion.md)，不新增删除范围或产品取舍。

## 问题与最终行为

原DeletionScreen把按钮直接绑定到控制器方法，仅依赖构建时的busy和控制器owner。真实页面/provider回归复现：账号busy后旧确认仍DELETE；范围重新读取完成但尚未重建时，旧确认采用新的scope；删除进行中旧保留仍能离页；旧范围读取、凭据核对和原请求重放也会在账号busy时发请求。

页面在激活时复验当前signedIn、owner、账号busy、当前provider/controller、目标sid及控制器busy。确认额外绑定本次View实际展示的不可变scope实例并要求当前仍ready，旧按钮不确认后来读取的范围。重新渲染并明确确认后，新范围正常提交。

独立初审指出路由切走而旧State仍mounted的遗漏。新增go/push→下一帧前调用旧确认/保留，四项均先复现失败，再补当前ModalRoute及GoRouter最新地址的目标路径检查。旧确认不发DELETE，旧保留不覆盖目标地址或pop新页面。

按钮和PopScope同时反映账号busy；非读取/删除阶段使用“正在处理，请稍候…”，避免误称正在读取范围。账号操作结束不会自动重试，需重新明确操作。8秒控制器截止、原key/body、未知回复核对、可信凭据后的scope清理、账号恢复动作和媒体占用规则均未改。

## 验证结果

| 检查 | 实际结果 |
| --- | --- |
| 删除Screen基线 | 17通过 |
| 首批RED | 新增11中7失败：busy删除、新scope确认、删除中/账号busy保留、load/check/replay；身份/失效provider的4项原已满足 |
| 初审路由RED | 新增go/push下旧确认/保留4项，全部失败；修补后通过 |
| 无效地址边界 | 另加1项，保留仍能离开且零请求；共新增16项常规回归 |
| 最终目标 | **50通过，约2秒**，含真实Screen/provider/controller及原4态Preview组件 |
| Flutter全量 | **1043通过，9项专用夹具默认skip，约36秒** |
| 分析/格式 | 无问题，2.3秒；206个Dart文件格式符合 |
| Node桥接 | **58通过**，含实际Dart编译桥接 |
| Web/字体 | release **36.2秒**；完整30,890映射、7,782,072字节WOFF2与本地Roboto检查通过 |
| 独立复审 | 路由漏洞已修补，最终三文件未发现剩余确定缺陷 |

正向回归还覆盖账号忙碌结束后重新读取、核对原凭据及明确重放原删除；重放的Idempotency-Key和body逐字等于初次请求。正常保留、无效地址保留、新范围确认、默认键盘保留、320/横屏/深浅色/200%字号，以及成功后清理/晚到读取、unknown警告与原失败边界继续通过。

HTTP使用MockClient控制回复，路由、账号/provider、DeletionController与View为实际生产代码。没有实际API/数据库调用、供应商或设备媒体；四态Preview的独立渲染属于组件测试，未宣称实际Previewer点击。所有Flutter检查均使用`--no-pub`，没有新增依赖或构建原生。

## 工作区与待验

[保留证据](evidence/2026-10-24-deletion-action-guards-preservation.json)：开工626个原文件无缺失，仅两个生产文件、一个测试文件及对应文档发生本单元修改；后端101个文件和四个依赖声明/锁文件均未改。未启动API/Web/Preview服务，未查询或迁移数据库，未提交、推送或部署。API720是本日前一HTTP修补单元的历史证据，未作为本客户端单元重跑结果。

浏览器工具本轮仍返回“Local browser use is disabled in Work settings”，实际浏览器Cookie/JavaScript、删除确认/返回/旧网址、B1最新修补与B3读取流程继续待补。Web构建和widget回归不代替这些操作验收。当前[B1–B6矩阵](../validation/2026-10-15-validation-plan.md#22-当前验收矩阵2026-10-24)已同步；真实语音、真实反馈、供应商可信终止/用量及完整基础版本仍未完成，模型输入继续按用户安排暂缓。
