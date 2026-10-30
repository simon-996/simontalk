# 复盘操作的当前页面资格

> **For agentic workers:** 按superpowers:executing-plans/TDD在持续开发中执行；用户要求完成一项接下一项，保存结果单元完成后直接接本单元。保留原工作，不提交/推送/部署。

**Goal:** 复盘旧按钮不能在页面切走、账号busy、当前来源/任务变化后提交整理或导航；有效原请求重试保持原key/body。

**Architecture:** 沿用删除/保存结果页已验证的当前Route+最新URI、owner/provider/controller与busy门；写操作绑定本次展示的封存输入，生成重试和结果导航还绑定展示job。Controller的固定动作、幂等、总截止和模型调用规则保持原状。

**Tech Stack:** Flutter、Riverpod、go_router与现有真实ReviewPageController/PracticeReviewClient；HTTP替身控制时机，无API/模型调用。

- [x] 检查现有复盘Screen，保留原测试基线；可控handler只扩展测试夹具。
- [x] 先RED：create/retry/pending在busy/go切页后零POST，refresh/text/locate/rehearse旧回调不请求/导航；刷新后旧生成确认不能使用新的completion；账号busy禁用但不冒充实际请求。
- [x] Screen补当前页面资格与展示source/job绑定；View增加独立accountBusy，操作禁用保留已有结果与真实状态。明确恢复后有效创建/重试仍可操作，原pending重放key/body逐字一致。
- [x] 目标与全量Flutter/Node/分析/格式/Web/字体，独立只读复核；新问题先RED。当前后端和供应商未改，不重跑API/付费连接。
- [x] 更新复盘契约、交互/验收/交接与工作区保留，清理临时日志/快照，继续下一项可独立工作；外部输入或浏览器实际不可用时保留缺项。
