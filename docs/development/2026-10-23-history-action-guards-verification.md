# 历史导航点击时校验验证

日期：2026-10-23。按[设计](../superpowers/specs/2026-10-23-history-action-guards-design.md)和[计划](../superpowers/plans/2026-10-23-history-action-guards.md)，核对基础功能跨入口衔接时，发现并修补历史页旧回调问题。

## 已复现和修补

历史页按钮由构建时metadata决定显示，但原Screen的若干回调未在点击时重新核对。实际Router/provider回归复现：仅改变ApiClient的当前owner，或通过真实HistoryController开始刷新，旧文字/复盘/删除/目标按钮仍跳原URL；旧“查看来源练习”进入`/history/null`。翻页到下一页后，旧行也能打开已不在当前页的记录。后端授权门仍存在，本轮没有证据表明这些跳转能跨账号读到内容，不将导航缺陷描述为越权读取。

Screen统一在点击时读取当前账号，要求signedIn、非账号busy、owner一致、原controller非busy；详情重新读取当前item并绑定URL，列表重新检查当前页成员。文字/复盘须仍sealed，来源/目标须仍rehearsal且有来源，关联须ordinary；URL来自当前已核对metadata。账号操作中当前按钮显示禁用，结束后恢复，不新增GET；读取提示仅由idle/reading决定，避免把账号busy误说成记录读取。

仅修改两个生产文件`history_screen.dart/history_view.dart`和现有`history_screen_test.dart`。未改变页面布局、业务接口、后端/schema、依赖或媒体行为；恢复/准备、删除及重练沿用现有真实模块，不增加占位功能。

## 证据

| 检查 | 实际结果 |
| --- | --- |
| 开工历史/重练基线 | 165通过 |
| 第一轮RED | 新增26回归中22失败/4通过；含真实路由`/history/null`、旧URL跳转、旧页行跳转，连同15原测试合计19通过/22失败 |
| 第一轮GREEN | 历史页41通过，历史/重练合计191通过 |
| 账号busy补充RED | 新增第27项先复现可见按钮未禁用，再复现把账号busy误显示为“正在读取记录…”；两处均先RED后修补 |
| 最终历史/重练 | **192通过，约6秒** |
| 最终Flutter全量 | **1009通过，9项专用夹具默认skip，约34秒**；新增27项常规回归，无新增wire |
| 分析/格式 | 分析无问题/2.1秒；206 Dart文件格式符合 |
| Node | 58通过，实际Dart编译桥接通过 |
| Web/字体 | 最终release构建34.7秒；30,890完整Unicode映射、7,782,072字节WOFF2及本地Roboto核对通过 |
| 独立只读审查 | 首轮守卫/26回归、末轮busy与提示/第27项均复核，未发现确定问题 |

26项包括六类详情旧回调在owner变化、读取中、账号busy时的18项、sealed变化2项、列表owner/读取/换页/账号busy4项和正常子来源/目标导航2项。第27项检查实际FilledButton/TextButton禁用及恢复、不增加GET与错误读取提示。正常原有文字/复盘/删除、关联列表和返回位置均由原回归继续验证。

所有Flutter测试/分析/构建均使用`--no-pub`；没有重新解析依赖。HTTP替身只用于隔离响应时机，路由、Riverpod、账号/历史controller和View均为实际生产模块。本轮没有启动API或创建数据库，也没有重跑真实Dart wire；原9项专用夹具skip不能计作实际互通成功。上批API709及实际wire结果只作历史证据。

## 浏览器与保留边界

本轮查询工具状态，浏览器列表为空并返回`Local browser use is disabled in Work settings`。未打开标签或Web/Preview服务，实际浏览器Cookie、点击/键盘和辅助技术仍待补，不以widget回归替代。没有新布局或组件样例，本轮不重新生成历史截图，也不将旧图记作本轮截图证据。

开工612个文件全部保留，仅本单元预期的客户端/文档发生变化；100个后端文件及两端4个依赖/锁文件摘要完全不变。数据库未访问、未迁移或写入；保留原工作分支及改动，未提交/推送/部署，无模型/原生调用。[文件保留核对](evidence/2026-10-23-history-action-guards-preservation.json)。

本单元完成历史导航衔接修补；真实语音、改善评价、浏览器/设备及基础版本整体验收仍未完成。
