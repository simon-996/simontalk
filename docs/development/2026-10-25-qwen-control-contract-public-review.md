# 实时语音控制契约：官方SDK与公开接口复核

2026-10-25。用户本轮明确要求“先只查公开资料”，未提交工单或联系供应商。无账号登录、供应商API/推理调用、开麦、服务启用或方案切换。核对公开资料及官方SDK源码，不能把SDK方法或替身测试当作型号实测。

## 当前Omni方案

所查官方Python SDK main固定在提交`4d3e9506e4470602664c8b5288c8b7c6fbe682a9`。未安装、执行或升级依赖；没有据此声称该提交已发布。

| 证据 | 对现有北京Qwen3.5 Omni的含义 |
| --- | --- |
| [旧SDK end_session](https://github.com/dashscope/dashscope-sdk-python/blob/4d3e9506e4470602664c8b5288c8b7c6fbe682a9/dashscope/audio/qwen_omni/omni_realtime.py#L535)发送finish并等待finished，close仅关闭socket | 发送封装不构成服务器支持保证；不能推翻本项目该型号finish返回invalid_value的真实观测 |
| [v2 delete_item](https://github.com/dashscope/dashscope-sdk-python/blob/4d3e9506e4470602664c8b5288c8b7c6fbe682a9/dashscope/v2/resources/audio/realtime.py#L610)发送删除事件；[结束检查](https://github.com/dashscope/dashscope-sdk-python/blob/4d3e9506e4470602664c8b5288c8b7c6fbe682a9/dashscope/v2/resources/audio/realtime.py#L738)对omni_v38特殊处理确认 | 同一模块覆盖多个协议，方法存在不能推定Omni3.5/3.8均支持或语义一致；所查模块未给独立REST终态查询路径 |
| [SDK测试](https://github.com/dashscope/dashscope-sdk-python/blob/4d3e9506e4470602664c8b5288c8b7c6fbe682a9/tests/v2/test_audio_omni_session.py#L28)使用FakeWebSocket与注入connector | 所查finish/关闭测试验证SDK自身状态机，不是供应商真实确认；本轮未运行这些测试 |
| [Omni总览](https://help.aliyun.com/zh/model-studio/realtime)与[WebSocket差异表](https://help.aliyun.com/zh/model-studio/realtime-websocket-overview)仍存在结束方式表述差异 | SDK也未消除冲突，不继续重复相同finish探针；最长会话时长不能补齐丢回包后的可信起算点 |
| [Omni客户端](https://help.aliyun.com/zh/model-studio/client-events)和[服务端](https://help.aliyun.com/zh/model-studio/server-events)事件页 | 本轮所查页面未找到truncate及对应确认，或可用于精确已播前缀的等效确认；不是断言供应商绝无此能力 |
| [Qwen-Audio删除请求](https://help.aliyun.com/zh/model-studio/fun-audiochat-client-events)及[deleted确认](https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-server-events)确有说明 | 属于另一模型族，不能把它套入Omni；整项删除也不自动等于保留精确已播前缀 |
| [Conversations API](https://help.aliyun.com/zh/model-studio/openai-compatible-conversations)有持久会话管理 | 文档针对Responses上下文；未给Realtime session映射或媒体终止语义，不能用其DELETE冒充关闭实时连接 |

工程结论：本轮没有新增足以解除现有unknown占用、确认停费或实现精确插话上下文的依据。保持原准入/信令关闭，不接假finish/截断确认，不因升级SDK或更换3.8型号便宣布问题解决。

## 已有RTC候选进一步核对

2026-10-26后续已补[恢复元数据/验签退出回调与Web SDK类型](2026-10-26-rtc-recovery-public-review.md)。新增4002退出回调候选及单发后核原任务的工程推导，未将缺幂等直接判为整条路线不可行；三份公开元数据仍未给重复/迟到创建与终态保留保证，Web公开类型仍缺精确已播前缀/上下文截断确认。未调用RTC业务API、未安装SDK或选用新路线；本节原时点结论保留。

仅比较此前已列出的RTC智能体控制面，未选用。不是把RTC、IMS AICall、AOQ或百炼会话的同名字段混用。

| 公开能力 | 可以据此规划的验证 | 仍不能推定 |
| --- | --- | --- |
| [StartAgent](https://help.aliyun.com/zh/document_detail/2937117.html)接业务指定TaskId；另需AppId/ChannelId/TemplateId及RTC权限 | 外调前持久化同一尝试身份，后续按同一三元组查询 | 页面没有给出足够的重复创建、并发同ID、失败后ID复用保证；不能直接实现自动重发Start |
| 同页UserInactivityTimeout默认30秒、范围5–180秒，覆盖目标用户未加入或已全部离开 | 分开验证“始终未加入”“正常离开”“断网尚未被识别离开” | 不能从本地退出时刻开始倒计时；需要服务端状态起点与状态查询，不当作费用硬上限 |
| [GetAgent](https://help.aliyun.com/zh/document_detail/2937118.html)给StartTime/StopTime及Status；3为正在停止，4为已经结束 | Stop后持续核同一任务终态；将受理和结束分开 | 未启动/查无对象/运行失败不能一律当安全释放，尚需排除迟到创建、查询保留期及ID复用 |
| [StopAgent](https://help.aliyun.com/zh/document_detail/2937122.html)接同一三元组，仅返回RequestId | 记录受理凭据，再GET核终态 | RequestId不是任务已结束，更不证明账单结清、精确播放或上下文截断 |

RTC在公开资料层面提供更具体的可查询控制面，但创建幂等/迟到启动与查无对象语义、终态保留、打断上下文/播放对齐、独立权限与费用、实际Flutter Web接入仍未验证。既有百炼Key不构成RTC控制面权限证明；本轮未索取新凭证、开通服务或新增依赖。

## 本轮结果与后续边界

脱敏[证据](evidence/2026-10-25-qwen-control-contract-public.json)记录3个SDK文件的固定blob、7份Omni相关官方页面和3份RTC接口说明。结论是现有方案仍缺契约；RTC只适合继续公开资料核查，不能标B2/B6完成。询问稿已补SDK/文档差异，保持草稿、不发送，按用户最新要求不再自动推进工单。

没有确定的应用代码缺陷，因此不添加外围功能或未具依据的供应商适配；没有重跑历史应用测试/构建、访问数据库、提交、推送或部署。开工820文件保留，4份原文档有意更新、816摘要相同，新增本报告/JSON；私有.env摘要不变、0600，临时核验文件已清理。本地引用、JSON、密钥隔离和Git空白已核对。
