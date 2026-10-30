# 原账号复盘任务客户端验证

日期：2026-10-21（Asia/Shanghai）。依据[设计](../superpowers/specs/2026-10-21-review-client-design.md)、[计划](../superpowers/plans/2026-10-21-review-client.md)和[实际客户端契约](../architecture/2026-10-21-review-client.md)。延续现有功能分支并保留全部既有dirty，没有提交、推送、部署、依赖升级、原生或真实模型调用。

## 1. 实现范围

新增11个Dart文件：4个生产文件（review_models/review_repository/practice_review_client/review_providers）、6个目标测试/fixtures及1个实际HTTP测试。没有修改既有客户端底层、UI、媒体或后端，数据库head仍8b2731f5ca90。

ReviewTarget只从sealed completion建立；输入只保存绑定/数量摘要，不留scopes原话或安全前文。任务及0–3项结果严格核对原账号/输入、业务态、枚举/UUID/日期/次数和不可变结构，hash与原话的权威校验仍在服务端。独立client提供明确创建、纯读刷新、保守生成重试和不确定HTTP动作的原key/body重放；输入到任务创建沿用最初key。构造/监听不发请求，没有轮询、浏览器持久正文或正式页面消费。

每个操作含CSRF及多请求共用8秒、独立HTTP fork，结束/超时/取消关闭；账号/来源变化清正文与动作，晚到不发布。确定409冲突清未受理动作并设needsRead，成功读取当前状态或明确未创建后才能由用户另作明确操作；失败读不解门、不自动换key。无正文锚点阻止输入/job更换、次数倒退和成功结果改写。未知调用阻止新生成，但原动作仍可用同key确认。

## 2. 主任务独立运行结果

| 检查 | 实际结果 |
| --- | --- |
| 完整`flutter test --no-pub --reporter expanded` | **642通过、4项默认跳过，17秒**；前批609/3skip，新增33回归及1隔离wire |
| Chrome `flutter test --no-pub --platform chrome --reporter expanded test/features/review` | **33通过，约4秒**，真实Chrome执行模型/状态/provider和替身HTTP |
| 隔离实际HTTP `test/integration/review_client_wire_test.dart` | **1通过，约3秒**；显式fixture运行，未跳过 |
| `flutter analyze --no-pub` | 无问题，1.9秒 |
| `dart format --output=none --set-exit-if-changed lib test` | 122个Dart文件、0改动 |
| Node `node --test test/web/*_test.mjs` | 58通过、0失败/跳过 |
| Web release，`--no-pub --no-web-resources-cdn` | 通过，31.3秒；无原生构建 |
| 字体源及发布包核对 | 完整30,890映射，WOFF2 7,782,072字节，本地Roboto及压缩中文字体一致 |
| 独立规格与质量审查 | 均通过，无剩余确定问题；审查agent只读、不运行数据库或测试 |
| 文档与工作区 | 38份变更Markdown、318处本地链接/锚点及围栏检查通过；git diff --check、锁文件检查通过 |

全量4项跳过分别为已有播放/固化/保存状态的隔离wire及本轮review wire；本轮wire已另用实际fixture执行。新模块的Web运行由Chrome33项覆盖，现有应用发布构建不表示正式复盘页面已经消费该模块。没有新增视觉组件，未将组件预览或旧截图作为本轮证据。

先区分缺符号RED和行为RED，再实施；根任务检查了ending仍可建target、创建前后key变化/输入hash未fatal/成功后invalidated未fatal、确定冲突pending不释放，以及初次409后未先读即再次POST的失败日志。修复后完整回归通过。测试还覆盖有效空建议/不可评价、非法结构/预算/日期/布尔/枚举/item ID/ordinal、原账号仓库、CSRF和多步总截止、单飞、dispose/账号变化晚到、未完成响应体取消、provider静默与释放，以及读到unknown/尝试3次后仍可精确确认原动作。

## 3. 实际Dart客户端到后台结果

临时API127.0.0.1:8001仅连接simontalk_test，注入fixture准入和异步gateway；真实供应商、信令及模型均未接。三个临时身份经实际注册/偏好/准备/连接/最终文字/end/manifest接口形成sealed来源；A/C各一句用户文字、B为空。ReviewInput和Job由实际Dart客户端创建，凭证只用于本机隔离夹具，不提交或输出。

| 场景 | 观察结果 |
| --- | --- |
| A默认能力不可用 | 实际POST已受理后，测试传输故意丢掉job回复；client得到network_error并保留原动作 |
| A纯读与确认 | GET读到blocked/0次，重复刷新无POST且保留pending；retryPending的body/key与原写一致，确认后清pending，没有新增gateway调用 |
| A明确重试，fixture成功 | runner异步完成succeeded、1次、1个经服务端精确引用核验的item |
| B空内容 | no_evaluable_content、0次、result=null；没有gateway调用 |
| C非法quote | failed/invalid_output、1次、无结果正文 |
| C明确重试，fixture空建议 | no_suggestions、累计2次、有效空items；与不可评价区分 |
| 已有终态再次请求/重试及GET | 无额外调用；最终恰success/invalid/empty三个fixture调用 |
| 身份与来源 | B读A任务404；仓库拒绝他账号target；A本机账号改变即清input/job/pending |

数据库精确观察为3个job、3个attempt、5个action、2份结果，和3次fixture调用一致。测试不证明建议语义正确或识别准确。临时API关闭，三个账号/邀请及其关联数据精确清理，夹具凭证文件移除；控制文件、脚本与字节码在交接前清理，非敏感验证日志保留。

## 4. 默认服务与数据保留

与开始时保存的开发库基线比对：revision仍8b2731f5ca90，17张表数量全部一致（原1用户/1邀请/11会话/1偏好，练习及反馈相关表均0）。没有给默认开发库写夹具练习或反馈。默认API8000原进程保持，live/ready均200，模型继续Unavailable；后端源码/迁移未改，不把前批API506与迁移证据标成重跑。

锁文件未变，原有工作全部保留；没有新增依赖、页面、媒体权限、原生构建、远端CI或部署。本轮验证范围是客户端请求/状态与跨端运行，不是完整复盘/重练、历史/删除、真实Cookie浏览器流程、真实语音或费用控制。

## 5. 下一步

将此能力接入复盘入口与真实状态/建议展示，沿用原输入、账号和来源失效门；正式页面需要自己的交互、可访问性及浏览器验收。真实模型权限/地域/预算及设备仍暂缓，一级重练、完整历史/删除和成本准入继续逐组实施。
