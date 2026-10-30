# 真实音频输入、截断探测与复盘worker组合验证

日期：2026-10-25（Asia/Shanghai）。按用户“继续”及既有20元首测授权执行。实现范围是既有能力的真实输入和组合核验；本轮只扩充测试工厂/用例，没有改应用源码、协议默认工厂、schema、客户端或仓库依赖。[实施计划](../superpowers/plans/2026-10-25-qwen-audio-review-integration.md)，[逐次脱敏证据](evidence/2026-10-25-qwen-audio-worker.json)。

## 真实音频输入

使用本机已有Samantha语音离线合成固定英文，不采集麦克风。16kHz、16bit、单声道PCM共126,754字节，3.961秒，按100毫秒块实时节奏上传；临时合成文件仅用于本次测试。模型为既有北京qwen3.5-omni-plus-realtime。

收到session.updated后才上传，配置手动模式和内置qwen3-asr-flash-realtime转录。音频完成只提交一次缓冲区，收到committed才请求一次模型回复。ASR最终结果与合成句逐字一致：

> Yesterday I went to the park. What do you like to do outdoors?

ASR final在commit发送后约0.336秒到达，首个回复音频包约0.716秒到达；回复生成完成在连接开始后5.823秒，收到222,720字节PCM。回复文字为“I love taking a slow walk through the woods to listen to the birds and feel the fresh air.”。没有播放或保存回复音频，时间不代表用户听见首声、真人识别准确率或大陆设备延迟。

ASR delta实测的text/stash为当前前缀/草稿快照，草稿出现“Yesterday.”随后修订为“Yesterday I…”；不能简单累计每条stash，也不能将早期标点当final。最终转写另以completed.transcript为准。没有confidence或字词播放时间对齐，不编造质量分数。

返回usage：输入517（文本489、音频28），输出80（文本22、音频58），总计597。虽然配置回显max_tokens=64，实际总output_tokens为80；不能把这个参数当作所有模态合计Token的硬限额。声音输出对应文本按该型号公开规则不重复计费，账单仍未核。

## 取消后截断

另一次独立连接用固定文本请求数数，首个音频包后仅发送一次response.cancel，约78毫秒收到cancelled；usage缺失仍为null。

随后针对实际返回的assistant item发送一次OpenAI样式conversation.item.truncate，content_index=0、audio_end_ms=0。因为没有设备播放，实验意图为移除全部未播放输出。千问当前专用事件表没有给出该控制契约；本次约29.127秒未收到截断确认或error，达到连接建立后30秒接收总截止，探针记录TimeoutError并关闭。未收到确认不能证明所有型号完全不支持，也不能当成功截断。

两次连接均收到双方1000帧；本机仍在12秒关闭截止附近清理。没有上游独立状态查询、可信失效起算点或回收上界，未将本地CLOSED记成可信终止。信令答案丢失、客户端消失、业务后端失联仍缺退出证据；正常语音准入保持关闭。已整理[供应商控制契约询问稿](2026-10-25-qwen-upstream-capability-questions.md)，尚未发送。

## 真实复盘worker

这是实际转写的**离线重放**：语音实验先结束，再在专用测试数据库通过真实API创建隔离业务范围、封存实际已观察到的ASR文字。没有把该业务连接冒充原实时会话；它没有发起上游信令，原状态not_started，不构成供应商结束证据。默认准入先验证503，只有该测试应用显式安装测试准入；默认signalling网关仍不可用。

显式安装真实qwen3.8-flash候选，经生产ReviewJob/claim/worker生成一次。结果为no_suggestions，attempt_count=1，合法空items；这句语法正确，不强凑建议。实际输入650/输出5 Token与review_attempts存储一致。

已验证以下实际ASGI/SQL操作：

- 同输入GET与再次运行worker均不重调模型，实际gateway调用数保持1。
- 本人历史可读，他账号读取详情及复盘404。
- 重建应用后保留默认Unavailable复盘网关，仍可纯读同一结果。
- 本人删除后，文字、复盘、来源及详情不可读；review_jobs/results/inputs及final_transcripts正文行均清除。

没有本轮浏览器UI验收，也没有实际通话页面→保存→反馈的实时闭环，B6仍未通过。

## 回归与费用

测试工厂exchange增加可选model参数，默认保持qwen-flash；六个既有SQL/worker场景同时核验旧型号和qwen3.8-flash：成功/用量持久化、合法空、非法引用、未知不重派、删除晚结果不恢复、同型号改变workspace时外调前阻断。新增6个组合用例；pytest中全部供应商请求仍为MockTransport，不读取真实私有配置或计费。

目标配置/组件/组合137项/6.27秒通过，Ruff、110文件格式及38包离线锁通过。独立只读复核120项纯组件/0.23秒通过，未发现确定问题；审查者未读私有配置、连DB或外网。首次扩展测试误改一处旧测试引用，出现NameError，修正后复验通过；该次失败不是产品问题。实际数据库只使用独立simontalk_voice_review_20261025_test，开发库仅做只读摘要核对。前批API全量1004、Flutter/Node/Web均保留历史，不重标为本轮执行。

按[官方北京标价](https://help.aliyun.com/zh/model-studio/model-pricing)计算，本轮已返回用量的语音约0.02453元、复盘约0.0005335元，共约0.0250635元；与前批相加已知部分约0.04080915元。取消响应无用量，未获取账单，总费用/剩余预算未知；该估算不是20元硬停费保证。

收尾已核：开发21表（含迁移记录）计数及全行摘要与开工一致；专属测试库在0连接时删除，临时合成音频/探针目录已移除。开工789文件保留，7份原文件有意更新、782份摘要一致，新增4份；302本地链接/JSON及11份变更文件和本轮临时文件私有Key扫描通过，.env仍忽略/0600，git diff --check通过。本轮没有提交、推送、部署或原生构建，语音/B5完整产品验收仍保留上述缺口。

官方参考：[客户端事件](https://help.aliyun.com/zh/model-studio/client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/server-events)、[WebSocket模型差异](https://help.aliyun.com/zh/model-studio/realtime-websocket-overview)。实验不会把其他模型事件、响应取消或本地状态套作供应商结束证明。
