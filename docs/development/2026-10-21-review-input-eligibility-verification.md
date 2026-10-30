# 持久复盘输入与原话引用门验证

日期：2026-10-21（Asia/Shanghai）。依据[设计](../superpowers/specs/2026-10-21-review-input-eligibility-design.md)、[实施计划](../superpowers/plans/2026-10-21-review-input-eligibility.md)、[接口与规则](../architecture/2026-10-21-review-inputs.md)及[集中契约第5节](../architecture/2026-10-20-practice-completion-and-review-contract.md#5-反馈依据与不确定性)。

## 实际交付

- 独立ReviewInput持久投影，以本人session/input_revision/policy_version固定原practice_input_hash及review_input_hash；新迁移**4c913f2d8e71**只增加review_inputs，不改变既有completion策略、输入hash或封存记录。
- 本人POST生成/精确重放及GET纯读。POST先鉴权/账号头/CSRF和User→Practice锁后身份复验，仅接受原sealed版本/hash；无封存、错误hash、他账号、不存在均有明确错误。重放返回原记录，并重新核对来源；没有自动模型调用或新建反馈任务。
- 存储快照只含精确scope/event/digest/turn/revision、纳入排除决定和上下文引用，不复制正文。每次读取与内部使用重算源payload摘要、member seal、global seal及独立review摘要，再重新派生比较，异常拒绝而不替换原文。
- 当前可用证据范围的eligible/uncertain/excluded规则：旧版本、AI、最新空文字排除；缺confidence为null/quality_source=unavailable，不因缺值或语法不标准排除正常句子。真实未final、无法核对的上下文限制相应判断；尾部不确认不自动否定更早正常话轮。
- AI背景只用原版本可靠played_text，首次freeze优先，不继承新final后缀。未知/撤销及无法定位的输出缺口限制相关后文；明确not_played仅省略。仅允许text_only的项不带残缺context；conversation_context只指原scope内可核对的前文，不承接旧epoch。
- 内部validate_review_suggestions限制0–3项，绑定本人/session/input版本及两hash/policy，检查精确原用户版本、连续Unicode原文、类型和允许basis；任一非法整批拒绝。不公开客户端自行提交假反馈的接口，不认证建议语义或原音准确。
- 请求接收8KiB/五秒；成员32、源事件8192、源文字4MiB、展开输入512KiB，先统计限界后取正文，重复context按实际展开计预算；超限不截断、不提交部分记录、不影响正常结束。

## 真实HTTP与内部存储

临时loopback API8001只使用独立`simontalk_test`和本机测试准入。三份身份、练习及连接均通过真实注册/偏好/准备/连接API建立，事件为明确测试文字，不是实测语音；本轮无需信令gateway、物理麦克风或供应商调用。

1. A提交6个最终文字事件：用户r1→r2、一个无播放证据的AI、其后用户句、另一用户r1→空r2；经真实end和manifest封存后POST复盘输入。得到**ready、eligible=1、uncertain=1、excluded=4**。较早的用户r2保留eligible及原文；AI之后的用户句仅允许text_only，旧句、AI生成后缀与被空版本覆盖的正文不进入目标或上下文。所有confidence=null。
2. 相同POST重放与GET返回完全相同记录/created_at/hash；GET为no-store，原completion响应保持一致。错误input_hash稳定409 review_input_changed，他账号读取为404。
3. B安全结束为空输入，成功建立**no_evaluable_content**，三类计数均0；这不是可自动重试的技术错误。C尚未end，POST准确409 completion_not_sealed。
4. 另以真实DB/session调用内部引用门：正确r2原话通过、空建议列表通过；有效项混入旧r1、AI文字、错误quote或不允许context依据均整体409 review_suggestions_invalid；旧hash为409 review_input_changed。检查A/B持久snapshot均无测试原文。
5. 停止测试API后精确清除三账号、邀请码及级联认证/偏好/练习/连接/completion/member/review输入，核对目标行0；本机凭证fixture、临时server/wire/guard/cleanup脚本及pyc删除。测试端口8001已无监听。

实测使用生产Api路由及服务、httpx和真实PostgreSQL，未用MockClient替代网络或保存层。内部引用门未对外开放，实测不代表模型已生成真实反馈。

## 检查与独立复核

| 检查 | 实际结果 |
| --- | --- |
| 根任务独立完整API | **462通过，85.66秒**；前批394，本批新增68项 |
| 实施侧完整API | **462通过，86.27秒** |
| Ruff检查/格式 | **通过，66个Python文件已格式化** |
| 测试库迁移 | **4c913f2d8e71 → 0e1874613efa → 4c913f2d8e71**降升；新表增删及alembic metadata无差异，根任务独立降升/check退出0 |
| 实际HTTP | 创建/重放/纯读、资格/正文边界、no-evaluable、未sealed、错误hash/他账号全部通过 |
| 内部原数据引用门 | 有效/空列表及四类混合整批拒绝、旧hash拒绝、无正文存储通过 |
| 原开发库升级 | **head 4c913f2d8e71**，原表数量逐项相同，新增review_inputs=0 |
| 默认开发服务 | 默认准入/网关继续关闭，API8000已重启，live/ready200，新GET未登录401 |
| Git与依赖 | 30份变更Markdown的264处本地文件/标题链接及diff空白检查通过；原工作全部保留，锁文件未变，无提交/推送/部署 |

先实跑缺路由RED（期望409、实际404），再实现。独立规格复核发现并补RED→GREEN：已有assistant final的unconfirmed输出可定位，不能降级更早话轮；仅有revoke墓碑不能充当位置证据，无法定位时即便清单未重复声明也限制scope；text_only项不得收到残缺context；无final但有playback的清单turn仍须有unknown/null/missing_final_text决定。另补源文字/摘要一起改变、已播前缀改变、预算和8KiB分块/五秒408等回归。最终规格复审通过后，独立质量审查通过，无剩余确定问题。审查仅静态读取，未并发操作测试库。

本轮Dart、Web及界面未修改，未重跑无关Flutter/Node/Web构建；上一单元609 Flutter/3项隔离夹具默认skip、Node58、Web37.4秒和完整字体验证保持各自时点，不能据此宣称新反馈页面已验收。当前未提供的ASR质量/语义歧义信号仍为unavailable，不伪造可信度；识别与建议质量仍需后续实际对话人工抽查。

日志本机保留`/tmp/simontalk-review-api-full.log`、`simontalk-review-wire.log`、`simontalk-review-guard.log`；无凭证输出。默认开发库原1用户、1邀请码、11认证会话、1偏好；练习、连接、观测、两账本、completion/member、termination及review输入均0，未写假练习。

## 剩余与下一步

下一单元接受本门约束的反馈任务与有效结果存储，保持输入版本/幂等/有限重试和删除后不可回写；真实模型账号/预算未提供时不能擅自调用。尚无模型反馈、正式复盘/重练/完整历史与用户删除页面，也无实际语音、可信终止执行器、设备或用量控制验收。本批推进学习闭环基础，不表示整个阶段完成。
