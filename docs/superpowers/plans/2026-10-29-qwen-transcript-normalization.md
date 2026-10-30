# 千问实时转写归一化实施计划

**目标：** 将单连接受保护通道上的千问用户和助手转写事件转换为现有对话投影可消费的完整快照，保持默认语音关闭。

**架构：** `apps/client/lib/features/realtime/qwen_transcript_normalizer.dart` 持有受限的供应商事件关联、UUID及revision；测试将其输出交给真实 `ConversationProjection` 验证。不会接入现有协议工厂或发送供应商请求。

1. 先测试用户 `speech_started`、`text+stash` 快照和 completed，以及助手 response/item/delta/done，确认先失败后实现；将结果实际应用到投影，校验AI播放仍unknown。
2. 测试事件ID重放/冲突、同项最终重放、非法关联/索引、final后delta及处置，失败后实现有界记录与失败封闭。
3. 测试正文/事件上限、无效Unicode、清理和跨实例隔离，运行定向Flutter、静态分析和格式；按实际测试更新交接。
