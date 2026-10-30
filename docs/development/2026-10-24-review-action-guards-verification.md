# 复盘操作资格验证

日期：2026-10-24。连续执行[计划](../superpowers/plans/2026-10-24-review-action-guards.md)，修补当前复盘页面的旧回调资格。实现见[契约](../architecture/2026-10-21-review-page.md#当前操作资格2026-10-24)。

## 行为和复现

整理、重试、原请求核对、刷新、文字/原话/重练跳转在点击时核对当前Route与最新URI、当前登录owner及账号busy、当前provider/controller和控制器单飞；生成绑定展示completion，任务动作和结果跳转绑定展示job。旧确认不能使用刷新后的新来源。原pending请求的key/body保持逐字一致，合法恢复后仍能创建/重试。

首批16项回归全部先RED，包含busy/切页后仍POST或GET、旧结果导航、刷新后旧生成提交新来源及账号操作显示。独立复核补出的旧重新连接在切页/账号恢复busy后的两个问题、销毁后读取WidgetRef的问题各自先RED；同时复现并修正忙碌时“练这一句”入口被隐藏，应保留禁用。最终复审无剩余确定问题。

## 实际验证

| 检查 | 结果 |
| --- | --- |
| 复盘目标回归 | 116通过，约5秒；新增19项Screen回归，原16项Screen基线保留 |
| Flutter全量 | **1113通过，10项专用夹具默认skip，约33秒** |
| Node桥接 | 58通过 |
| 静态与格式 | 分析无问题/2.1秒，215个Dart文件格式符合 |
| Web release | 33.5秒；30,890映射、7,782,072字节WOFF2及本地Roboto全部通过 |
| 独立只读复核 | 已关闭三项确定问题，最终无剩余确定问题 |

同批为保存结果页补了四态五张本地中文字体组件渲染，4项通过且逐张实际查看，详见[视觉补充](2026-10-24-saved-practice-status-verification.md#组件视觉复核补充)。实际浏览器仍被Work设置禁用；组件、桥接和构建证据不代替Cookie/JavaScript/实际Previewer验收。

本单元只改客户端Screen/View、回归与文档，不改变ReviewPageController、PracticeReviewClient、HTTP/幂等协议；未运行API/数据库/供应商调用，后端API720为先前历史证据。后端101文件和四个依赖文件保留，未提交/推送/部署，原生构建继续暂停。[工作区保留](evidence/2026-10-24-review-action-guards-preservation.json)。

保存结果三个任务及本项完成后，继续核对重练确认和文字回看当前页面资格。真实语音、正式通话/结束补交、真实反馈与完整B2/B6仍未完成。
