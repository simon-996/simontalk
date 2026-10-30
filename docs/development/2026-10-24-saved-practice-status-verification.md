# 每次练习保存情况验证

日期：2026-10-24。按用户“完成一项继续下一项”的持续要求，连续完成[计划](../superpowers/plans/2026-10-24-saved-practice-status.md)三个任务：独立读取控制器、历史入口/页面/清理、实际后端隔离联调。实现见[契约](../architecture/2026-10-24-saved-practice-status.md)。

## 产品行为

任意本人历史详情可进入独立保存情况页，按真实记录展示未登记、保存中、完整/有缺口及逐类说明。返回历史详情后继续查看原有文字或复盘。页面不需要当前练习仍占用、不需要已选难度或供应商账号。保存结果、整次连接待核对和实际用量分开说明。

两次本人GET共8秒且状态/coverage一致后才整体发布；刷新立即撤旧，网络/身份/来源错误不保留旧成功。明确未登记只能来自合法详情及completion_not_found；不会把删除或他人记录当未登记。旧刷新/历史入口检查当前路由、owner/controller和busy。可信删除凭据失效新的纯读family，保留订阅也清除旧结果。

## 结果

| 验证 | 实际结果 |
| --- | --- |
| 控制器 | 25通过：静默构造、2次GET、单飞、未登记、保存状态/coverage冲突、严格owner/target/格式、8秒和迟到/身份清理 |
| 页面 | 22通过：历史入口/返回、恢复与不可达保留地址、实际difficulty=null、未知/保存中/缺口、失败撤旧和明确重试、旧按钮与真实200%字号/320/375/横屏/深浅色 |
| Preview组件 | 4个独立样例通过，完整、缺口大字、保存中和失败；未启动实际Previewer |
| 衔接RED | 新保留订阅与账号busy文案两处先观察失败，再补family失效和独立accountBusy反馈；新模块最初测试因模块缺失RED |
| 目标回归 | 175通过，约7秒，含全部历史目录；原删除/父子/unknown/迟到读取行为保留 |
| Flutter全量 | **1094通过，10项专用夹具默认skip，约39秒**；新增51项常规及1项可选wire |
| Node/分析/格式 | Node58通过；修正新增代码的6处括号规范后分析无问题/1.3秒；215个Dart文件格式符合 |
| Web/字体 | release33.3秒，30,890映射、7,782,072字节WOFF2和本地Roboto通过 |
| 独立复核 | 控制器与页面/路由/删除衔接两轮只读审查，未发现确定缺陷 |

## 实际后端互通

在本轮新建的专属_test库运行迁移及现有真实HTTP夹具，生成一条通过end/manifest封存且tail_unconfirmed的记录、一条未登记取消记录，以及已通过DELETE隐藏的记录；另有独立B账号。夹具准入只在测试app中注入test-only，不调用供应商，实际uvicorn使用默认关闭网关。

Dart生产控制器在真实API上验证封存缺口、未登记404、B拒读A、已删拒读、再次刷新hash不变。每轮8个请求全部GET；停止并重启API后再执行一轮，两轮均1项通过。每轮前后包括alembic_version的所有表全行摘要一致。[互通证据](evidence/2026-10-24-saved-practice-status-wire.json)与[数据库证据](evidence/2026-10-24-saved-practice-status-database.json)仅保留非敏感结果。

开发库全程只读快照，20业务表和迁移记录全行不变；没有schema升级或注入假练习。专属API/数据库、测试setup文件与私有fixture已清理。后端生产与依赖未改，未把API720作为本单元重跑；未调用模型、构建原生、提交、推送或部署。[工作区保留](evidence/2026-10-24-saved-practice-status-preservation.json)。

实际浏览器工具重新核对仍提示Work设置禁用，未执行Cookie/JavaScript、前进后退或真实Previewer点击；widget/wire及构建不代替这些验收。真实语音、正式结束保存操作/队列重试、真实反馈与完整B2/B6仍未完成。完成本单元后继续核对复盘操作的当前页面资格，不逐单元等待用户再说继续。

## 组件视觉复核补充

使用本地完整中文字体，以生产View渲染四态、五张PNG并逐张实际查看：浅色[完整](screenshots/saved-practice-complete.png)、[保存中](screenshots/saved-practice-saving.png)、[失败](screenshots/saved-practice-failed.png)，及深色320宽200%字号的[缺口顶部](screenshots/saved-practice-gap-dark320-200.png)/[滚动底部](screenshots/saved-practice-gap-dark320-200-bottom.png)。4项渲染测试通过；长说明正常换行、滚动可达底部，未见异常裁切或溢出。此为组件渲染，不是实际浏览器或Previewer验收。
