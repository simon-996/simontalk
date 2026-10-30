# 一级重练来源与独立准备契约

日期：2026-10-22。对应[设计](../superpowers/specs/2026-10-22-rehearsal-preparation-design.md)、[实施计划](../superpowers/plans/2026-10-22-rehearsal-preparation.md)与[验证报告](../development/2026-10-22-rehearsal-preparation-verification.md)。本文件初始单元仅完成后端目标读取、独立准备与关联读取；2026-10-23已补[客户端确认/准备与只读目标](2026-10-23-rehearsal-client.md)，真实媒体及改善评价仍待接入。

## 1. 模型与一级关系

沿用PracticeSession及原mode=free_chat、偏好快照、占用门、准入和生命周期。新增kind=ordinary/rehearsal（默认ordinary）及source_session_id、source_kind、source_review_item_id、rehearsal_target、rehearsal_target_hash。普通记录新增来源字段全空；重练必须完整保存来源和目标对象/hash，不能指向自身。

迁移`1a6de74c9f20`承接`8b2731f5ca90`，不增加业务表。唯一键`practice_id_owner_kind`和复合外键`practice_rehearsal_source`强制同账号ordinary父，阻止跨账号、多级派生及父类型篡改；ON DELETE CASCADE删除直接重练，单删子不影响来源/同级。存在重练记录时降级明确拒绝，不能静默丢失目标；无重练时可降升且保留历史普通记录。数据库删除关系已验，不等于用户删除范围确认流程已完成。

同级列表按source_session_id/user_id及created_at/id的部分索引读取，仅索引kind=rehearsal；匹配父来源过滤和倒序seek，不依赖扫描账号全部历史。

## 2. 本人端点与目标

| 方法/路径（均在/v1/practice-sessions下） | 行为 |
| --- | --- |
| GET /{source_sid}/review-items/{item_id}/rehearsal-target | 当前有效普通来源建议派生目标，纯读 |
| POST /{source_sid}/review-items/{item_id}/rehearsals | 固定target_hash和可选difficulty_override，Idempotency-Key创建/确认独立准备，201 |
| GET /{child_sid}/rehearsal-target | 核对固定快照并重新验证当前源，纯读 |
| GET /{source_sid}/rehearsals | 本人普通来源的同级记录元数据分页，纯读 |

沿现有Bearer/Cookie、X-Account-ID及POST的Origin/CSRF和锁后身份复验；匿名401，他人/未知来源404。POST在解析前受8KiB、五秒接收门限制。来源未就绪或已变化409；有效空建议和未知item为404。错误不回显原话或内部异常。

目标为rehearsal_target_v1，source=server_derived，evidence_source=client_reported，固定账号/普通来源/item/job/result hash、原输入与策略版本/hash、connection/client_instance/epoch/turn/revision、完整source_text、exact_quote、类型/依据/解释/建议、安全context_before及target_hash。situation_mode=source_original；当前不生成新场景或新示例。

先复用review完整来源/结果/quote门，再匹配原scope的非excluded用户decision；不可只按turn UUID找句或只保存引用片段。text_only前文为空，conversation_context只取原允许的同scope安全前文。旧AI前缀保留原修订，不能补成后来未报告已播的生成全文。仍受既有32连接/8192源事件/4MiB等来源限额；目标实际UTF-8 JSON（含hash及转义）不超过64KiB，原话/引用/建议各8192字节、解释16384字节，拒绝NUL。

冻结hash为除target_hash外目标canonical JSON的摘要。读取子目标先验证固定字段/结构及存储摘要，再重算当前完整目标逐字段比对；失效409，但不删除子记录或其独立文字。同级列表不要求源review仍有效，子自己的文字仍走既有保存文字规则。

## 3. 原子创建与重放

新请求摘要绑定operation=rehearsal_create、source_sid、item_id及完整body。先核对同owner/key摘要冲突，再按User→普通父锁序核验当前目标及确认hash。共用build_preparation只检查占用/偏好/准入并构造未保存对象，不add/commit；包装函数设置完整kind/来源/目标后一次提交，默认Unavailable返回503且无半记录。

同key同请求返回原记录，不重新准入、改变时间或配置快照；变hash/item/override或将key改用于普通准备均409。新key须经过原占用门，上次安全结束后可新建同来源同item的第二条同级记录，使用当时偏好。重练不复制来源转写，不覆盖原练习；当前没有重练语音提示词或双维度改善评价。

## 4. 同级分页与实现位置

列表limit默认10，范围1–20；before_id必须是同账号同父记录。按(created_at,id)倒序seek，读limit+1判断next_before_id，返回id/kind/来源item/status/created_at/ended_at，包含取消、失败及完成记录，无原话/目标正文。非法游标404，不按offset跳页。

新增rehearsal_targets.py、rehearsals.py和rehearsal_routes.py；models.py维护约束/索引，practice.py提取共同构造并给PracticeOutput增加可兼容字段，main.py注册router，offer_body_limit.py加入POST门。现有Dart普通准备解析器忽略额外字段，本批未改Flutter、依赖或锁文件。

## 5. 验收界限

实际供应商准入、信令及反馈gateway仍默认Unavailable。隔离HTTP验收注入本地admission/反馈夹具，只证明契约与事务，不能证明语言建议质量、设备出声、可信终止或费用控制。完整历史、用户删除确认与学习闭环仍缺；前批保存文字页面的实际浏览器/Preview点击验收继续待补。最终命令、数量和清理以[验证报告](../development/2026-10-22-rehearsal-preparation-verification.md)为准。

## 6. 客户端后续接入（2026-10-23）

[客户端契约](2026-10-23-rehearsal-client.md)接普通建议入口、独立目标确认/本次难度/固定key创建、未知回复原样确认及安全discard；历史子目标只读。未设全局难度只能读取并去设置，不能以override绕过preferences_required。真实Dart/HTTP证明503无半写、丢已受理回复不重复准入、两独立同级、取消及来源失效后子历史保留；[报告](../development/2026-10-23-rehearsal-client-verification.md)。本批没有新增连接或媒体，正式语音/改善评价仍未接入。
