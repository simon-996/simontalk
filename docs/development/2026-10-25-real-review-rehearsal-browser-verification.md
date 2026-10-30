# 真实建议到一级重练确认与准备的页面验收

2026-10-25，沿用[既有重练契约](../architecture/2026-10-23-rehearsal-client.md)，补验真实模型建议进入目标、独立准备及历史回看。当前Flutter Web release晚于全部lib源码，未重建；桌面IAB实际视口1280×720，真实Cookie/CSRF、API及独立PostgreSQL17参与。

## 来源与准入边界

一个合成账号，日常难度beginner/v2。通过真实API封存两句固定英文：`Yesterday I go to the park.`、`I usually take the bus to work.`。准备/封存仅使用测试准入，没有真实媒体；不向开发账号注入样本。

标准`create_app`显式qwen配置，页面明确整理后，由生命周期runner真实调用一次`qwen3.8-flash`，HTTP200、689输入/49输出Token。结果引用`I go`，建议`I went`，解释过去时；这是本轮新的真实结果，非重放前批响应。没有修改网关或HTTP响应正文，观测只加请求计数和状态。实际账单未核，沿用用户已确认的20元首测预算。

普通日常配置仍disabled，正式语音准入/信令未开启。浏览器先验证真实Unavailable准入503；其后只在独立测试进程中，通过私有控制文件启用现有测试Admission，以验证准备成功路径。测试Admission不能当作模型准入、可信退出、实际重练语音或改善评价成功。

## 页面与SQL核对

| 操作 | 实测结果 |
| --- | --- |
| 真实建议旁“练这一句” | [目标页](screenshots/browser-real-rehearsal-target.png)同时展示完整原句、短引用、建议和原解释；初读仅GET，没有新建子记录 |
| 选深入表达并确认，仍使用Unavailable准入 | 真实POST503，页面[明确未登记](screenshots/browser-real-rehearsal-unavailable.png)，旧目标撤下；SQL重练记录0，无半写 |
| 明确重读、测试准入下重新确认 | 上游201已受理，代理仅延迟成功回包9秒，记录耗时9.086秒；页面按既有截止显示[结果待确认](screenshots/browser-real-rehearsal-unconfirmed.png)，没有自动再POST |
| “确认上次准备请求” | 真实201恢复[已有准备](screenshots/browser-real-rehearsal-prepared.png)；请求key和body摘要与迟到请求相同，child ID不变，SQL仍只有1条子记录，测试准入只调用1次 |
| 难度与连接 | 第一条effective_difficulty=advanced，原偏好beginner/v2不变；连接epoch0，子连接0，页面提示语音尚未开启 |
| 安全放弃 | 真实discard-preparation200，[第一条取消](screenshots/browser-real-rehearsal-cancelled.png)且保留记录；不宣称已终止供应商，因为从未启动子媒体 |
| 返回原复盘，同句再进入并确认 | 新控制器默认回beginner；产生第二条不同ID的created准备，测试准入累计2次；两子目标/hash一致，同一普通父及建议，第一条仍cancelled |
| 第二条记录→查看重练目标→重载 | [固定目标只读](screenshots/browser-real-rehearsal-readonly.png)，完整原句和建议保持一致，没有难度或确认新建入口；重载恢复同一子地址，没有新增POST |
| 子详情→来源详情→关联重练 | [两条关联记录](screenshots/browser-real-rehearsal-related.png)分别显示已登记准备/准备已取消，不覆盖来源；来源仍为原已保存自由聊天 |

共30条浏览器API请求，均转发真实后端；唯一注入为延迟一份201回包，没有伪造服务响应。四次重练POST分别为503、迟到201、同请求核对201、第二次独立201，三个不同key；核对没有重复准入。服务端成功写出迟到回复，不能声称网络层丢包；页面仍保持待确认，未接纳迟到结果。

最终1用户/3练习（1父、2子）、2条原始测试转写、1任务/1尝试/1复盘结果；子转写和子连接均0。真实模型仅调用1次，读取、准备、取消、关联和重载均不重调模型。脱敏SQL、Token、请求摘要及截图摘要见[证据](evidence/2026-10-25-real-review-rehearsal-browser.json)，不含密码、Cookie、token、长期Key或原始幂等key。

## 收尾与剩余范围

7张截图均已实际查看，未发现需修改应用的确定问题。本轮没有源码/schema/依赖变化，未重跑历史API1042、Flutter1401或Node58。测试标签13、API8001/Web7357及专属库已清理，开发21表全行摘要不变；私有.env未改/0600，临时账号凭证、控制文件、脚本及观测文件已清理。

开工810文件全部保留，3份原文档有意更新、807份摘要不变；新增计划、报告、JSON及7张截图。无原生构建、提交、推送、部署或联系供应商。真实业务语音/改善评价、广泛模型语义、手机/大陆网络及B6仍待验；后续集中处理B2可信上游退出/失效与播放截断，已有询问稿尚未发送，不重复同类探针或增加外围占位功能。
