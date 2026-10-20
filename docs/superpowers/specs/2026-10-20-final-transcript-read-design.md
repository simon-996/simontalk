# 最终文字的客户端读取与查看

## 目的与取舍

在已实现[文字追加/读取API](../../architecture/2026-10-20-final-transcript-storage.md)上增加受账号保护的客户端读取和只读查看。按用户持续开发授权选择常规工程实现，不等待额外确认；真实模型、预算、设备输入继续跳过。

采用独立的不可变分页模型/重建器，复用现有恢复控制器的请求互斥与8秒截止，在现有记录面板展示。相比把文字当观测事件，它可保留修订与正文预算；相比新增完整历史页/任意ID查询，它不超出当前只有未结束练习快照的入口。不存在记录时不造假内容，UI不自动创建练习、信令、麦克风或文本提交。

## 读取模型与不变量

新 `final_transcript_read_models.dart`：

- `FinalTranscriptEvent.fromJson` 严格解析event_id/sequence/turn_id/turn_index/role/revision/text/response_id/provider_item_id/received_at/delivery_status，ID规范小写，整数拒绝bool/double/string；字段界限沿用服务端。合法UTF-8、不含NUL，text≤8192字节，provider ID 1–256 Unicode字符。received_at必须有时区且日期时间有效；不反射原文到异常。user必须null response/delivery，assistant必须UUID response且delivery=unknown；delivery字段不得缺省。只接最终文字，不合成临时或播放事实。
- `FinalTranscriptPage.fromJson(json,{required scope,required afterSequence,required limit})` 对 source=client_reported、全部账号/练习/连接/client/epoch、统计/游标/has_more、排序和事件ID唯一性核验。单页≤32条，总数≤512，文字预算≤1MiB，total≤last，total=0当且仅当last=0，bytes≤total×8192；空/满/末页和请求游标必须一致，单页字节不大于总预算。
- `FinalTranscriptHistory.empty(scope).append(page)` 原子生成新历史，保留≤512条追加事件/1MiB/256turn。每页必须从原cursor继续，不能更换scope；已知水位/统计不倒退，count增长对应last增长（delta count≤delta sequence），count相同不得改bytes。跨页事件ID不重复，同turn index/role/response/provider固定，revision严格增加，index不能被别的turn占用。当前turns选最大revision按turn_index排序，保留空最终修订。已读事件/字节不能超过统计，末页必须精确相等，不把部分读取显示成全量。
- 提供 `scope/events/turns/lastSequence/totalEvents/totalTextBytes/nextAfterSequence/hasMore`、`hasSequenceGaps/hasTurnIndexGaps/hasRevisionGaps`。缺口是可观察间隔，不能证明具体文字丢失；revision也可能包括未持久化临时字幕版本。AI永远只是生成文本，无可用AI播放上下文，也不判断服务器固化/反馈资格。

`PracticeRepository.loadFinalTranscripts(connection,{afterSequence=0,limit=32})` 仅GET，携带原account header，构造ConversationScope并严格解析原连接响应；坏查询在发请求前invalid_request，坏返回统一invalid_response，错误不带原文。

## 生命周期与交互

PracticeRecoveryController新增 `transcripts`（FinalTranscriptHistory?）、`transcriptErrorCode`、`loadingTranscripts`、`loadTranscripts({bool refresh=false})`。使用现有互斥操作；没有原连接不读，读完不自动重复；请求前后核验账号、独立HTTP fork，8秒总截止及取消。首次读取空history.append；翻页错误保留已接受文字及原cursor，显式重试；刷新文字先清空文字再从0读；全局refresh/清理/身份错误/dispose清空文字。身份变化后getter和旧操作不得返回旧正文或恢复晚响应；已交给消费者的不可变快照不能远程擦除，UI必须跟随账号provider。

UI在现有连接记录下增加 `FinalTranscriptReadView`：按钮“查看已保存文字”，读取中明确文字状态，分页“查看更多文字”，失败“重试读取文字”，读过后可“刷新文字”。身份错误不显示正文，按既有“重新确认账号”路径处理。标题“已保存文字”，来源说明“来自客户端提交的最终文字，可能有遗漏。AI 内容为生成文本，不能确认已播放。”；AI角色显示“AI 生成内容”及“播放情况未知”，用户显示“你”，空最终文字明确“此段没有可用文字”。显示已读提交数/本次总数、当前段数；部分读取显示“尚有文字未读取，当前内容可能继续更新”，间隔仅说明完整性不能确认，不输出具体缺失文本。不显示UUID/epoch/sequence/raw error，不生成反馈/得分。

列表按当前turns使用有界高度ListView.builder及滚动条，完整显示/选择长文本，不截断原话；按钮换行排列，深浅主题、窄屏/横屏/200%字号不溢出，至少44px交互目标，键盘可访问、载入状态liveRegion。沿用现有主题与字体、响应式/预览规范；预览样例只在预览与测试中存在。

## 验证与范围

先失败测试再实现：严格分页/身份/字节/日期/播放状态；跨页修订/缺口/映射/预算/统计原子拒绝；控制器GET-only/失败cursor/刷新/超时/取消/账号变化/删除404；widget实际provider接入、长文/字号/主题/键盘。全Flutter/分析/格式/Node/Web release/字体；实际loopback API+独立PostgreSQL测试页32+后续修订、GET无业务写、失败与账号隔离；浏览器与预览检查。无后端业务/迁移变化，保留276项后端证据并仅按实际改动复验，不把新文字读取称为完整历史或断线恢复。
