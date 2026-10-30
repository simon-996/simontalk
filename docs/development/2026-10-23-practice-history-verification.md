# 本人历史列表与详情验证

日期：2026-10-23（Asia/Shanghai）。依据持续开发授权，完成基础路线B3工程接入；当前本地`feat/account-foundation`保留前置及本单元改动，未提交、推送或部署。

## 1. 交付行为

- 首页“记录”接本人分页历史，普通练习与一级重练使用原数据库记录；详情展示原难度、登记时间、业务/保存状态及独立连接占用提示。
- sealed详情进入原保存文字/复盘，初进只读；返回原详情及原列表页/滚动位置。重练详情可回来源，未封存没有完整文字入口。
- 每页10项，稳定tuple seek；独立8秒/单飞/身份清理/迟到拒绝。没有记录时展示真实空态，不向开发账号写演示练习。

具体字段、游标与错误见[接口契约](../architecture/2026-10-23-practice-history.md)，产品范围见[规格](../superpowers/specs/2026-10-23-practice-history-design.md)。

## 2. 自动验证

| 检查 | 实际结果 |
| --- | --- |
| API全量 | 664通过，209.69秒；新增历史23项 |
| Flutter全量 | 861通过，38秒，6项独立HTTP夹具默认skip；本批真实history wire另跑1项通过 |
| Dart分析/格式 | 无问题（3.6秒）；171个文件格式检查通过 |
| Python静态/格式 | Ruff通过，86个文件格式通过 |
| Node Web桥接回归 | 58通过 |
| Web release | `--no-pub --no-web-resources-cdn`通过，47.3秒；同源API，无依赖升级 |
| 本地字体 | 30,890映射，完整Noto Sans SC 17,772,300→7,782,072字节；Roboto本地资源通过 |
| 迁移与metadata | 隔离库head→1a6de74c9f20→head、Alembic check通过；开发库仅索引升级到2d4836ab9c10 |

开工先验证原48项API/41项Flutter；新接口起初404、Flutter文件缺失及首页无记录导航均先观察失败。分页模型补了请求边界回归。独立质量审查发现极端带时区日期转换可溢出，先补HTTP回归观察503，再捕获OverflowError返回400；最终复审无剩余确定缺陷。该审查独立运行历史44项Flutter，当时尚未加入最后3项键盘/未设难度回归。

API覆盖空态、身份/跨账号、同时间记录、插入/删除边界后seek、非法limit/cursor、原难度快照、普通/一级来源、sealed与unknown独立、摘要无正文、查询数量/零提交及索引。Flutter覆盖严格模型/游标/原子拒绝、GET-only仓库、分页保留/刷新清空、8秒真实timer和迟到门、dispose/账号变化、恢复/深链接/未设难度、文字/复盘返回及滚动位置；320/375/横屏、深浅色、200%字号/减动效、键盘及5项preview widget通过。

## 3. 真实HTTP与数据保护

独立数据库`simontalk_history_6dad40a085_test`运行真实API8001及同源Web代理7357，默认准入/信令/反馈网关Unavailable。A为23条（普通来源1、同级重练1、同时间普通21），B为1条；来源23段保存文字、1项有效反馈为独立测试种子，不是实际模型输出。

生产Dart仓库/控制器真实连接API，读A三页10/10/3、回上一页、sealed原难度、23段文字16+7、已有1项复盘、B隔离及跨账号404，全部GET。额外HTTP检查外账号游标400、23项无重复；API优雅重启后响应一致。读取前后19张业务表全行排序摘要完全一致，没有创建新任务、媒体或模型调用。[HTTP摘要](evidence/2026-10-23-practice-history-http.json)。

另在隔离事务插入20,000条普通记录做默认planner首/tuple seek `EXPLAIN ANALYZE`，均为`practice_history_owner_seek`逆向扫描且无Sort，之后回滚。开发库迁移前后19张业务表全行摘要一致，仍1用户/0练习/0连接/0文字/0复盘，未注入种子；[数据库及查询计划证据](evidence/2026-10-23-practice-history-database.json)。

## 4. 页面证据与待验范围

本批浏览器工具返回`Local browser use is disabled in Work settings`，未创建标签，未执行实际导航/分页/网址刷新/后退前进/键盘/断网/跨标签身份检查。Previewer服务已成功启动，但实际界面同样无法打开，不能标点击通过。组件测试不替代浏览器验收。

通过临时widget capture以现有Noto字形渲染并逐张查看五态，截图是独立样例组件，**不是实际浏览器或真实练习页面截图**；capture测试脚本用后删除，正式5项preview测试保留：

| 样例 | 截图 |
| --- | --- |
| 浅色列表 | [760宽](screenshots/practice-history-render-list-light.png) |
| 深色窄屏大字 | [320宽/200%](screenshots/practice-history-render-list-dark-320-200.png) |
| sealed且连接待核对 | [详情](screenshots/practice-history-render-detail.png) |
| 真实空态样式 | [空态](screenshots/practice-history-render-empty.png) |
| 网络失败样式 | [错误](screenshots/practice-history-render-error.png) |

新页实际浏览器与Previewer，以及前批保存文字页浏览器补验均保留待办。没有真实语音、手机、可信终止、模型语义质量、删除或完整产品验收。

## 5. 收尾与下一步

临时API/Web/Preview进程、专属库及其账号/凭证/脚本清理后核对端口和开发库。默认API8000本轮开始即未运行，不额外启动。原工作区与依赖锁文件保留，495个开工文件无缺失，12份文档297个本地链接及围栏、git diff --check通过；未请求原生构建或付费调用。

下一工程单元为B4删除：按已确认父删全部一级重练/单子隔离、完整范围版本复核、正文/晚到结果清理及unknown占用独立保留设计和实现。B2/B5待模型/地域/预算输入后接真实语音与反馈。
