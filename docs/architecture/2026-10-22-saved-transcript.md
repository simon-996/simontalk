# 已封存文字读取与复盘原话定位

日期：2026-10-22。对应[设计](../superpowers/specs/2026-10-22-saved-transcript-design.md)、[实施计划](../superpowers/plans/2026-10-22-saved-transcript.md)及[验证记录](../development/2026-10-22-saved-transcript-verification.md)。后端与独立客户端已实现，最终验收进度以验证记录为准。既有[复盘来源页](2026-10-21-review-page.md)、[输入资格](2026-10-21-review-inputs.md)、[结果引用门](2026-10-21-review-jobs.md)及[固化契约](2026-10-21-practice-finalization.md)保持原约束。

## 1. 本人只读端点

GET `/v1/practice-sessions/{session_id}/saved-transcript`，查询必填`input_revision=1`、小写64hex的`input_hash`；可选`offset`（0–8192）、`limit`（1–16，默认16）、`review_item_id`（UUID）。身份沿现成session_identity/X-Account-ID；匿名401，其他账号或不存在练习404。普通读取不要求ReviewInput或ReviewJob存在。

新增`saved_transcript_routes.py`和`saved_transcripts.py`；`main.py`只注册router，无迁移、依赖或配置开关。GET不创建输入/任务/动作，不commit业务变化，不续租、结束或恢复媒体，不调用gateway。

先沿原`_completion`确认本人sealed输入，再用`review_inputs._load_sources`核对原事件payload/schema/digest、完整成员范围、manifest、snapshot及member/global hash。额外核对全局coverage/gap_codes与已验证成员的摘要一致，按原`practice_completion._turns`重算话轮选择并比对snapshot，防止正文引用或选择被单独更改后继续读取。限额在原来源materialize之前聚合核验：32连接、8192源事件、4MiB源文字；投影最多8192段，每页最多16段，实际UTF-8 JSON响应不超过512KiB。超限返回409，不伪装空记录。

未封存沿原`completion_not_sealed`；输入/hash/来源/有效结果变化409 `saved_transcript_changed`；超过读取范围409 `saved_transcript_limit_exceeded`。未知建议404 `review_item_not_found`；已有非成功任务暂不能定位时409。错误不回显原话或内部异常。

## 2. 页和角色语义

响应为`saved_transcript_v1`，`source=server_derived`、`evidence_source=client_reported`；固定包含本人账号/练习、revision/hash、sealed_at、coverage/gaps、total_turns、offset/limit、previous_offset/next_offset、focus及items。全部nullable字段显式存在。每项保留原connection/client_instance/epoch、turn_id/index/revision、role和全局ordinal，按成员epoch/连接再按话轮顺序排列，不按客户端时间或文字相似度拼接。

- 用户：当前最高最终修订，revision>=1；final_source=final_transcript，final_text可为空，所有播放字段null。最新空修订不恢复旧文字。
- AI最终文字：原FinalTranscript优先；无该行时只接受同当前修订且transcript_final=true的PlaybackEvidence，标`playback_final`。没有最终文字则text/source均null。合法无转写freeze可形成revision=0，不能把临时生成内容补作final。
- AI播放：原封存interrupted_prefix优先、final_prefix其次，回原同scope事件取正文，核对话轮及文字/播放版本。played_text与played_revision只表示该客户端报告的片段；更早修订保留其自身前缀，不扩展到新最终文字。同response撤销优先为revoked并清前缀。not_played须有同当前最终文字的有效证据；否则unknown。revision=0没有最终或已播文字。

所有正文字符串不含NUL，最多8192 UTF-8字节。客户端报告与seal均不证明设备实际出声、可信上游终止或语言识别准确性；这一页不提供音频回放。

普通省略offset从0开始。items数量精确为`min(limit,total−offset)`、ordinal从offset+1连续；previous在offset>0时为`max(0,offset−limit)`，next为尚未到末尾的offset+本页长度。offset等于total允许合法空终页，超过total为422；total=0只有offset0，双游标null。

## 3. 建议定位

`review_item_id`只由本人当前有效ReviewJob/Result解析，沿原`read_review_job`的完整result hash、ReviewInput和精确quote校验。成功结果中不存在该item为404；不存在任务同样404。已有任务未成功或结果/来源失效为409。核对原sealed输入、成员连接、用户话轮与当前修订及非空精确原话，不按turn UUID单独选句，跨连接复用相同UUID仍分别定位。

focus包含原item/job/result hash、connection/turn/revision/exact_quote及全局ordinal。初次省略offset从ordinal−1读，使目标成为首段。显式offset用于浏览前后文，每页继续携带并重新核对同一item，不因为离开目标页就放弃引用校验。

## 4. 客户端接入边界

新增`features/transcript/`下models、repository、controller、providers、screen、view、previews及独立preview_fixtures共8个生产文件。原ReviewClient生成与固定动作门不改；ReviewPageController只增加导航资格getter/实际item归属校验，screen在点击时重新确认当前本人target、busy和item，而非信任先前闭包。sealed来源即开放“查看已保存文字”，独立于任务成功；成功结果每项提供“定位到对话”。

构造和监听零HTTP。初读/刷新先清旧内容，再GET completion→GET saved-transcript，两步共一次8秒操作期限；分页各8秒，共享单飞future、独立fork、取消/迟到/账号守卫。当前只保留一页最多16段。刚读页面的sealed_at、coverage、gaps须与刚确认completion一致，翻页还核对总数/封存输入/focus等固定锚。分页网络失败保留上一接受页并明确说明，沿原游标重试；401/账号变化/404/来源或形状失效清空正文与焦点，不保留旧原话。

新仓库在解JSON前用ApiClient可选`maxResponseBytes`核对实际bodyBytes，含大量空白的超512KiB响应也拒绝；旧调用默认不启用新上限。新模型强制固定字段/nullable、UUID/hash、范围/游标/连续ordinal、角色来源和精确焦点，正文按UTF-8字节/NUL及成对UTF-16 surrogate核验。数学整数值必须在既定范围内；Web数字表示不区分1与1.0，非整数、boolean、负值与超界仍拒绝，不承诺JSON词法层的整数字面量校验。

路由为`/practice/:sessionId/transcript`和`/practice/:sessionId/transcript/:reviewItemId`，只包含UUID，不把quote/hash放入地址。沿既有GoRouter实际网址反映选项及incoming编码历史规则，将有效阅读路径扩展到普通/定位页；账号恢复/失联保持地址，已登录但未设难度也能读，无效ID不发练习请求。原复盘push新页、pop保留原建议位置；直接地址没有可pop页面时“返回复盘”回同session review。

## 5. 阅读与当前界限

纯view使用项目主题、max680、SafeArea和响应式16/24/32边距；标题后是稳定的返回/刷新/前后页/回原话动作区，动态状态/正文位于其后。按钮至少48，窄屏换行；正文可选择复制，目标原话有文字及轮廓标记，连接段与实际ordinal/total明确。只给状态和段落标题适当语义，正文及展开的生成全文没有liveRegion祖先；ExpansionTile自身展开/收起控件状态可独立播报。

AI已报告播放片段为主要内容，旧版另标“此前版本”；生成全文独立折叠并明确不代表已播放。unknown、not_played和revoked各有说明，无final/prefix的段落说明没有可用文字。没有音频回放、重练或删除占位动作。独立浅色定位/多连接、深320/200%文字、空态和错误预览使用previewWithFonts，不依赖账号/API。

默认模型/实际语音仍Unavailable，封存与客户端播放报告不证明设备出声或可信终止。一级重练、完整历史列表及删除另行实现；这一页读取当前32/8192/4MiB有界封存来源，不宣称任意大小的全部历史均已支持。

## 阅读操作资格（2026-10-24）

点击时复验当前Route与最新URI、已登录owner、账号非busy、当前provider/controller及控制器非busy。翻页/原话定位/记录行绑定本次展示page，旧回调不能作用于随后读取的新页，即使新页包含同一ID。刷新仍纯读。返回检查当前页面/owner/provider和账号busy，但允许真实读取期间离页。账号操作提示与实际读取分开，保留已读页并禁用动作。

未连接旧恢复先检查mounted和当前路由，再读当前账号；只在仍不可达且非busy时恢复。关联列表异步翻页完成及post-frame聚焦再次核对当前页面/owner/provider及accepted page，覆盖或离页后不抢焦点。Controller/Repository/分页与总8秒协议未改。见[验证](../development/2026-10-24-reading-action-guards-verification.md)。
