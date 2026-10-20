# 最终文字的客户端读取契约

对应[设计](../superpowers/specs/2026-10-20-final-transcript-read-design.md)与既有[文字存储](2026-10-20-final-transcript-storage.md)。本批增加GET消费、修订重建与偏好页“未结束练习”中原连接文字查看，不提供全练习历史列表、媒体恢复、结束固化或反馈。实际语音准入/网关/协议工厂保持关闭。

## 解析与重建

`FinalTranscriptEvent/Page/History` 均为不可变final类，列表不可变。页面核对source=client_reported及原account/session/connection/client instance/epoch，严格整数、UUID、带时区有效接收时间、合法UTF-8/NUL、单条8192字节、provider ID最多256个Unicode字符。必须显式提供delivery_status：user为null，assistant只能unknown且带response UUID，绝不从文字存储生成播放事实。

页游标是追加sequence，不是turn_index。最大32条，统计受512修订/1MiB约束；排序/ID/游标/has_more/数量/字节预算相互一致。合法after_sequence超过last时可返回空页，history本身从0开始追加。与内存ConversationProjection不同，读取重建不会套用其256KiB当前文字限制；服务端合法的1MiB历史及Unicode provider ID可读。

History按原scope与cursor续读，验证累计统计不倒退、数量增长与水位增长一致、单事件最大字节及未读剩余额度。候选全部事件成功核验后才返回新对象；冲突页不能部分污染当前内容。同turn的index/role/response/provider固定、revision严格增加，index不可被其他turn占用，跨页event ID不可重复。末页的累计事件数/文字字节必须精确等于统计。

`events`保存已读取追加修订，`turns`选同turn最大revision并按turn_index排序。空字符串的新修订覆盖旧原话，保留“此段没有可用文字”；不会过滤空修订而复活旧文本。sequence/index/revision间隔合法，以独立flags保留；它们不能证明缺少哪句原话，revision可能包括未持久化的临时结果。每页是独立查询快照，读完也不等于服务器已封存；后续刷新可能发现新增版本。

## 请求与生命周期

`PracticeRepository.loadFinalTranscripts`仅GET既有原连接端点，始终传原X-Account-ID；坏参数发前invalid_request，坏响应固定invalid_response，不回显正文。

PracticeRecoveryController在显式动作后读取，构造/读取provider本身惰性。所有恢复/观测/文字/明确准备清理共享一个进行中操作，重复动作返回原future，不在后台排队。每次请求使用独立账号ApiClient fork和HTTP所有权，总截止8秒并用单调时间二次核验，释放HTTP不关闭源账号客户端。

首读和翻页通过不可变history原子发布。翻页失败保留已接受版本与原cursor，用户可明确重试；刷新文字先清空、从0重新读取；全局刷新、清理完成/拒绝/未确认、身份错误及销毁清除全部文字。文字读取404清除已不可用的原记录，需刷新当前状态。账号/销毁取消进行中请求，晚响应不恢复内容；getter也检查原账号，防保留controller暴露旧正文。已经交给消费者的旧不可变快照无法远程擦除，消费者必须随账号provider丢弃它。

## 查看组件

恢复面板只在真实查询到connection时提供“查看已保存文字”；AI生成内容独立标“播放情况未知”。已读数、本次总提交数和当前段数区分；分页未结束说明当前内容可能继续更新，间隔仅说明完整性不能确认。不给准确性/播放/反馈资格保证，不显示内部ID、原始错误码，不提供纠错输入。

FinalTranscriptReadView使用项目主题、独立且有界的惰性ListView/ScrollController/可见Scrollbar及SelectionArea，完整阅读/选择长文；按钮位于阅读区外并可换行。阅读区支持上下方向和PageUp/Down键，Tab可离开到外部按钮；不承诺边界PageDown自动滚动外层。仅状态变化设liveRegion，避免读屏器持续播报全部原话。组件预览/测试样例有明确边界，未注入实际应用数据。

最新并行文档审查确认的正常结束文字收尾、识别可靠性、重练改善规则继续适用；本批只读工作没有把当前同步stop升级为有界收尾，也没有实现这些后续能力。
