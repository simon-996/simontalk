# 正常结束、固定补交与输入固化验证

日期：2026-10-21（Asia/Shanghai）。依据[设计](../superpowers/specs/2026-10-21-practice-finalization-design.md)、[计划](../superpowers/plans/2026-10-21-practice-finalization.md)、[当前接口](../architecture/2026-10-21-practice-finalization.md)和[收尾契约](../architecture/2026-10-20-practice-completion-and-review-contract.md)。

## 实际交付

- 正常结束先通过原连接end原子登记唯一结束意图、全历史成员范围、ending和首次受理后固定30秒截止；同key同内容重放不延期。drain结束后提交不可变manifest，保存两个账本全部已接纳事件的ID/sequence及数量/字节、pending快照和明确缺口。历史member与origin摘要分别验证，不能用旧连接结束新epoch。
- 两账本和首次manifest在原锁序内复核截止及封存状态，截止相等即到期；新事件/新修订拒绝，精确既有记录仍可确认，混合批次整体回滚。manifest后只允许清单内尚未收到的事件补交；序号缺口不自行推导丢失。
- 核对所有成员实际事件集合和统计，完整覆盖可提前固化，明确缺口继续保留；到期由maintenance按实有记录固化，进程重启继续，不依赖客户端在线。origin始终必须等待manifest，空历史豁免只适用于首次end前已安全终结且更早epoch的空not_started连接。
- 固化保存版本1、确定性hash、每scope不可变引用/覆盖/缺口，不复制第二份正文。最新final、同版本播放和旧版本首次freeze分别引用，撤销排除前缀；空白用户final排除，playback-only未final或未知输出保守标缺口。候选资格`final_text_candidate_v1`供后续完整资格派生使用，不是识别准确性或反馈资格认证。
- ended/completed父状态受连接清理/信令失败保护，结束后不再续租、创建新连接或接纳晚信令答案。unknown仍占用；end、首次失联/失败unknown及维护补齐登记原attempt去重的blocked/capability_unavailable终止核验意图，attempts=0，不调用上游或伪造confirmed。
- 客户端两个journal在ACK/finish后保留无正文清单、abort同步清除。独立completion client使用固定key/body、8秒原账号HTTP请求与有界只读刷新；失败显式重试，refresh不暗中重放写。正常end同步停麦停声和3秒窗口不受HTTP影响；空TurnStarted纳入缺口，收尾故障也登记意图和aborted清单。
- 服务器sealed摘要之后先验证原scope及全局hash的receipt，再按实际已收到事件结清两queue；永久缺失记permanentlyUnsavedCount/sealed_unsaved，取消在途请求、忽略晚ACK并释放正文，不冒充ACK。账号作用域保留未确认end/manifest/receipt与重试操作，结清后可释放。普通未收到正常end意图的异常stop仍保持原中断语义。
- 播放读取支持sealed从false到true，固化后统计固定且不可倒退；recoverable始终false。现有文字UI仍显示AI播放unknown，本批没有正式练习/保存界面。

## 真实Dart、HTTP和PostgreSQL

临时loopback API8001只使用`simontalk_test`和测试准入；本机测试gateway返回合成SDP，没有任何供应商网络调用或物理音频。维护间隔临时设1秒，标准开发配置仍15秒。实际Dart http.Client、ApiClient、两journal、completion client及repository连接真实FastAPI/PostgreSQL，未使用MockClient：

1. A账号实际交换本机测试信令，服务器记录原attempt及unknown终止；提交2条播放事实（r1 partial与首次freeze）和用户final，随后end受理。窗口内再提交AI r2 final，固定完整manifest并固化。数据库核对A在**首次受理后0.058秒**固化，coverage=incomplete仅保留tail_unconfirmed；生成final r2没有继承播放，旧prefix仍引用r1。
2. 读取scope快照、严格receipt和已sealed播放分页；receipt确有2条最终文字、2条播放事件。产品状态completed，原连接unknown、termination unknown、原租约截止不变。相同end key和文字事件精确重放成功，hash/sealed_at不变；新文字稳定409 practice_input_sealed。B访问A completion为404。
3. B账号end后不提交manifest，Dart实际等待31秒，不修改服务器时钟/时间字段。后台在**首次受理后30.355秒**固化，缺口为manifest_missing和tail_unconfirmed。
4. B随后用真实journal提交1条晚文字，服务器409，pending仍为1。迟到manifest也409，completion client转只读摘要/receipt，得到实际收到0条；journal收据结清后pending=0、permanentlyUnsavedCount=1、errorCode=sealed_unsaved，没有伪造保存成功。
5. 直接数据库核对两份版本1/hash、两scope快照、2条文字/2条播放；两连接均仍unknown占用，恰好2个blocked核验任务且attempts均0。随后精确删除两临时账号/邀请码和级联completion/manifest/snapshot/两账本/核验数据，逐项确认关联记录0；删除仅测试夹具清理，不代表实现用户删除HTTP。

本实际链路**1项通过，约31秒**，日志`/tmp/simontalk-completion-wire.log`。`test/integration/practice_completion_wire_test.dart`需要`SIMONTALK_COMPLETION_WIRE_FIXTURE`指向本机隔离凭证夹具；默认全套明确skip。临时API、凭证和种子/清理脚本已清除，没有开发库练习或模型调用。本批没有浏览器Cookie、真机或物理媒体验收。

## 最终检查

| 检查 | 实际结果 |
| --- | --- |
| 后端全套 | **387项通过**，71.53秒；前批344，本批新增43 |
| Ruff | check通过，60个Python文件格式无更改 |
| 测试库迁移 | d41a7c9e2b60→新head降升通过，3新表消失/重建及metadata check无差异 |
| 开发库迁移 | head `0e1874613efa`；原用户1/邀请1/登录会话11/偏好1及练习、连接、观测、文字、播放0数量保持；3新表均0 |
| 开发API | 新源码已重启；live/ready均200，新completion路由未登录401；默认准入和网关仍Unavailable |
| Flutter全套 | **565项通过、2项隔离夹具测试明确跳过**，约15秒；前批534，本批新增31 |
| 独立实际HTTP | **1项通过**，与上述skip分开记录 |
| Node | **58项通过**，约0.75秒 |
| 分析/格式 | flutter analyze无问题，2.1秒；103个Dart文件格式0更改 |
| Web release | **35.8秒通过**；no-pub/no-web-resources-cdn，API127.0.0.1:8000 |
| 发布字体 | 完整30,890 Unicode映射，WOFF2 7,782,072字节，发布文件与本地中文/Roboto一致 |
| 依赖 | pubspec.lock和uv.lock无差异，无依赖升级 |
| 文档与空白 | 23份Markdown、214处本地链接/标题锚点及围栏通过；git diff --check通过 |

本机检查日志：`/tmp/simontalk-completion-api-full.log`、`/tmp/simontalk-completion-flutter-full-first.log`、`/tmp/simontalk-completion-node.log`、`/tmp/simontalk-completion-analyze.log`、`/tmp/simontalk-completion-web-build.log`及`/tmp/simontalk-completion-fonts.log`。Wasm dry run不等于Wasm或原生验收。

## 失败回归与审查

后端先实际观察8项缺end端口的失败，客户端先观察缺submission/completion端口和封存读取行为失败；媒体接入先观察缺factory/待处理状态/重试方法失败再实现。早期测试命令的目录误用不计行为RED证据。后端曾误并行启动两个自动清库的测试进程，产生401/邀请失效和死锁；该轮结果废弃，之后严格串行测试，最终387项为独立完整通过结果。

设计复核修正origin被当空历史而过早seal、候选引用误当完整反馈资格、manifest缺截止门，以及不完整seal导致永久保活四处边界。实现规格复核发现并以回归修复：只读refresh暗中POST重试、历史member误按自身身份校验全局origin、SQL nullable hash/digest CHECK漏IS NOT NULL。另真实并发暂停GET的用例复现旧事件统计配新sealed状态，改用单SQL快照；补not_played、空白final、playback-only缺口及确定锁序回归。

最终独立规格复审及后续独立代码质量审查均未发现剩余确定问题。审查只读，不替代root的实际HTTP、数据库和全套检查。

## 边界与下一步

seal只固定客户端申报输入；没有证明真实转写准确、设备输出、供应商完成/截断、可信终止、用量结算或费用封顶。blocked终止任务没有执行器，不会自动变成成功；实际准入/网关/协议继续关闭。恢复仍不得自动把已固化输入当供应商上下文，unknown占用仍阻止下一连接。

本批尚无正常结束之外的自动产品end策略、正式练习/保存UI、完整反馈资格/任务、模型建议、逐句重练、完整历史或用户删除HTTP。下一单元将固化状态、实际缺口和需维护状态接入现有真实只读恢复入口，再推进可引用的完整复盘输入；供应商账号、地域、预算及设备条件继续按既定暂缓边界处理，原生暂停。

工作保留在`feat/account-foundation`，前批全部未提交改动保留，本单元未提交、推送或部署。
