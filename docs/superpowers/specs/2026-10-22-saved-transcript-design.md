# 复盘原话定位与整次已保存文字

日期：2026-10-22。承接[复盘阅读页](../../architecture/2026-10-21-review-page.md)、[封存契约](../../architecture/2026-10-21-practice-finalization.md)和[原连接文字读取](../../architecture/2026-10-20-final-transcript-read.md)。持续工程授权覆盖常规可逆选择；保留当前功能分支全部dirty，不提交/推送/部署，不调用真实模型或恢复原生。

## 范围与选择

交付复盘中的“定位到对话”和“查看已保存文字”，跳至独立可刷新的本人阅读页。点击建议定位同一sealed输入、实际来源连接/话轮/修订；返回保留建议页和滚动位置。没有复盘任务、不可评价或生成失败时也能读取已经封存的文字。不是完整历史列表、转写纠错、重练、删除或音频回放。

方案比较：

| 方案 | 取舍 |
| --- | --- |
| 在复盘页内展开全部文字 | 与建议共用滚动区，来源/分页/失败容易推走焦点和原建议位置 |
| 独立阅读页（采用） | 单独管理身份、分页和定位；真实网址/刷新/返回栈可验，复盘保持原位置 |
| 只打开目标句弹窗 | 实现短，但缺少整次保存文字和前后文，不能满足本单元 |

## 服务端：只读封存投影

新增GET `/v1/practice-sessions/{session_id}/saved-transcript`。沿现有session_identity及X-Account-ID；他人/不存在404。查询参数：`input_revision=1`、`input_hash`小写64hex、`offset`可省略（0–8192）、`limit`默认16且1–16、`review_item_id`可省略UUID。只读，不创建ReviewInput/Job/Action，不结束或续租连接，不调用gateway，不commit业务变化。

先确认本人sealed completion并匹配原revision/hash，再复用既有`review_inputs._load_sources`的完整payload→member→global校验：账号/成员scope、事件schema/digest、清单、引用/统计、snapshot及global hash均成功后才派生文字。保留现有32连接/8192源事件/4MiB源正文上限、聚合后再materialize，超过明确409，不返回假空。阅读不要求ReviewInput或Job存在；这一界限与当前复盘可处理范围一致，不宣称全部任意大小历史均可读。异常映射为稳定无正文错误。

按completion成员epoch/connection顺序，再按sealed turn_index/turn_id投影当前话轮。旧修订不复活；空的最新用户修订仍是一段无可用文字。sealed中只有播放证据的AI话轮也保留，缺最终文字时不能把中间生成内容当final。每次最多16段，响应UTF-8不超过512KiB。

### 线格式

响应字段固定：

```text
schema_version: saved_transcript_v1
source: server_derived
evidence_source: client_reported
account_id, session_id, input_revision:1, practice_input_hash
sealed_at, coverage:complete|incomplete, gap_codes
total_turns:0..8192, offset, limit, previous_offset:int|null, next_offset:int|null
focus:null|{item_id,job_id,result_hash,connection_id,turn_id,revision,exact_quote,ordinal}
items:[{
  ordinal,connection_id,client_instance_id,epoch,turn_id,turn_index,revision,role,
  final_text:string|null, final_source:final_transcript|playback_final|null,
  playback_status:null|unknown|played|partial|not_played|revoked,
  played_text:string|null, played_revision:int|null
}]
```

user要求revision>=1、final_source=final_transcript、final_text为合法UTF-8字符串（可空），playback字段全null；assistant的最终文字来自原final transcript，或无该行且有同版本transcript_final=true的playback最终生成文字。没有最终文字则final_text/final_source均null，绝不拿临时版本补齐。assistant允许既有untranscribed freeze派生的revision=0，此时final_text/final_source/played_text/played_revision均null，playback_status为unknown（同response撤销仍优先revoked）；有效播放前缀的played_revision须>=1。字符串各最多8192 UTF-8字节，无NUL；UUID/整数/枚举/nullable形状严格。

AI播放前缀以封存turn的interrupted_prefix优先、其次final_prefix，与原payload/版本核对；任一同response revoke使播放证据失效。prefix可属于更早transcript revision，只保留其本身played_text与played_revision，不扩展到当前final后缀。not_played必须有当前最终版本的实际证据；无有效证据为unknown。文字内容不能证明设备确实播放或可信终止。

普通读取省略offset等同0；定位请求省略offset时从目标ordinal−1开始，使目标为首段，避免自动扫描此前所有页。显式offset允许翻到前/后页；合法范围0..total（total>0时不能读超出total的偏移）。items ordinal须连续且从offset+1开始，长度=min(limit,total−offset)；previous=max(0,offset−limit)（offset>0），next=offset+长度（未到末尾），否则null。空记录offset0/items空/双cursor null。

### 定位门

有review_item_id时读取本人当前有效ReviewJob/Result，沿已有完整result hash/quote门；只接受成功结果中的真实item ID。确认其input绑定本次seal、source_connection属于成员、source_turn/revision是该用户话轮、exact_quote为原text精确非空子串。无任务或成功结果中无此item为404；已有非成功任务暂不能定位、结果失效/篡改为409；不能按文字相似度、只有turn UUID或客户端传来的quote选句。

focus给出原item/job/result hash及目标ordinal。当前页含目标时必须与实际user条目连接/话轮/修订及quote包含关系一致；客户端初次定位必须验证首段就是目标。翻页仍带同review_item_id，服务端重新核对，不允许失效后继续显示引用。封存来源变化或完整性失效统一409 `saved_transcript_changed`，有界读取超过限额409 `saved_transcript_limit_exceeded`；未封存沿既有`completion_not_sealed`。

## 客户端与路由

新增独立严格models/repository/controller/provider和纯视图/screen，复用原ApiClient及sealed目标，不改既有ReviewClient安全门。新仓库在解JSON前按实际bodyBytes限制512KiB（含空白），ApiClient只增加默认不启用的可选上限；正文额外拒绝NUL及孤立UTF-16 surrogate，合法emoji保留。构造/监听零HTTP；页面首次仅GET completion→GET saved-transcript，两步共用一次8秒操作期限，独立fork/取消/迟到/账号保护。分页GET也独立8秒，只持有当前最多16段，不在本地累积整份正文。

初读/刷新先撤旧；下一页/上一页网络失败保留原已接受页和cursor，明确说明仍是上一页，允许原操作重试。401、账号变化、404、hash/格式/来源失效清空正文及focus；构造/销毁/账号getter不允许旧内容回流。外层单飞，重复动作复用future，晚响应不得发布或发后续请求。相同已确认输入跨页total/coverage/gaps/sealed_at/focus锚不变；变化原子拒绝。

路由`/practice/:sessionId/transcript`、`/practice/:sessionId/transcript/:reviewItemId`，地址只含UUID，初次定位不在网址保存quote/hash。沿复盘的incoming encoded history规则保留恢复/失联阅读路径；已登录无难度也可阅读，无效ID零HTTP，signedOut仍走原登录。复盘push阅读页保留栈；直接地址“返回复盘”回原session review，不开媒体。复盘入口按钮点击时复核当前本人source/busy和item归属，避免过期闭包。

“查看已保存文字”由sealed来源开放，独立于模型成功与否；三类建议各有“定位到对话”。仅真实item允许定位，预览回调为no-op。既有复盘上不放重练/删除占位。

## 阅读呈现与可访问性

max680、项目主题/字体、SafeArea、LayoutBuilder 16/24/32边距、整页滚动。标题后稳定动作区放返回/刷新/上一页/下一页/回到原话，按钮至少48，可换行；动态保存/错误/正文在后，避免回填推走键盘焦点。段数/分页来自实际ordinal/total，scope边界用“连接段1/2…”说明，跨连接不拼成连续同一段音频。

目标用户话轮有文字“建议对应原话”及轮廓标记，保留原text不改写，quote可选择复制；目标为首段，不循环扫描或强制抢焦点。其他页可明确“回到原话”重新读取目标。屏幕阅读器只播关键状态，标题/段落标签有heading语义，不用整份正文liveRegion。

用户最终文字可选择；空修订显示“这段没有可用文字”。AI有效已播前缀作为“客户端报告的播放片段”，旧版本另标“此前版本”，不显示未播后缀为已发生对话。生成全文以独立可展开“查看已保存生成文字（不代表已播放）”呈现；unknown/revoked/not_played文字区分，不能仅靠颜色。无final/无有效prefix清楚说明没有可显示文字。识别文字/保存缺口提示沿既有约束，不显示发音分数、真实费用停止或音频播放按钮。

新独立预览浅色定位/多连接页、深320/200%文字、空/错误，使用previewWithFonts和明确示例，无API/凭证。320/375、横向矮窗、两主题、200%/减少动画、键盘焦点与正常文本选择均验。

## 验证与清理

后端先真实RED，再测未登录/他人、sealed版本、纯读零写、无review可读、分页/offset/空修订、多scope同turn UUID、AI partial/旧prefix/revoke/unknown/playback-only、精确item门、删改/限额与响应字节。客户端测严格页/nullable/offset/focus锚、单飞/8秒/取消、分页失败/刷新清旧、路由刷新/历史/身份、真实按钮及返回滚动。

单实施agent先后端、规格审查后质量审查，再客户端同流程；root独立API/Flutter/Chrome/Node/analyze/格式/Web字体及隔离真实浏览器/Preview。默认开发库17表/head前后相等；独立临时账号/数据/凭证/服务/标签清理。默认Unavailable，不把fixture反馈或播放证据当真实语言质量/供应商/设备验收。
