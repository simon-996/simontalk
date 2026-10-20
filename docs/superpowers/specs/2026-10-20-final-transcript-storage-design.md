# 最终文字提交与读取设计

当前内存投影有最终用户转写及 AI 生成文本，但没有服务器确认。本批建立原账号、练习、连接、client instance、epoch 绑定的追加记录与确认队列，供后续正式练习入口使用。沿用用户持续开发授权，自主选择以下可逆工程方案；不涉及供应商、付费、部署或新产品决定。

## 方案选择与边界

采用追加最终文字修订，而非覆盖整份对话（会丢失引用版本）或保存每个临时字幕（无必要且放大隐私与容量）。播放证据继续在内存模型中独立存在，本批不持久化播放证据，读取的 AI 文本始终明确 delivery_status=unknown；不能据此判定已听到、生成反馈或最终固化练习。服务端不接收临时文字、音频、供应商原始事件。source 固定 client_reported，仅代表客户端申报。

## HTTP 契约

`POST/GET /v1/practice-sessions/{session_id}/connections/{connection_id}/transcripts`。
POST 使用现有 Origin、CSRF、X-Account-ID 和 User→Practice→Connection 锁后身份复核。输入 `client_instance_id`、`epoch`、`events`（1–4）。每个事件：UUID event_id、正32位 sequence、UUID turn_id、正32位 turn_index、role=user/assistant、正32位 revision、text、可空 UUID response_id、可空 provider_item_id。endpoint 含义固定为最终转写；不允许 is_final、source、播放或额外字段。

单条 text 可为空（最终撤回修订），合法 UTF-8、不含 NUL，最多8192字节；provider_item_id 非空时1–256 Unicode 字符、合法 UTF-8、不含 NUL。user 不得带 response_id，assistant 必须带 response_id。同连接 turn_id 的 index/role/response/provider 映射固定，index 唯一；新修订必须大于已接收版本。允许索引/版本/sequence 缺口，不补造缺失记录。同一 event_id 精确重放确认原记录；不同内容或重复 sequence/turn revision 冲突409；低 sequence/revision409。批次递增 sequence、ID唯一，整体核验后原子提交。

每条连接最多512个最终修订、256个不同 turn、累计文字1MiB；重放在满额后仍可确认。POST body 限256KiB、总接收5秒，JSON验证不回显文字。每个事件保留服务器 received_at、摘要及原连接身份的复合外键，关联删除级联。历史/未知连接可以补交其原文字，不修改任何练习/连接状态、租约、终止或准入。练习/账号已删除不可重新创建内容。

ACK 包含 source、account_id、session_id、connection_id、client_instance_id、epoch、last_sequence、total_events、total_text_bytes、acknowledged_event_ids（原顺序）。GET 以 after_sequence（0..2147483647）、limit（1..32）读取追加历史，返回同身份与预算、水位、events、next_after_sequence、has_more；每条 AI 输出 delivery_status=unknown、user=null。读取按单条连接快照分页，后续新增可继续读取；不是跨分页冻结会话。最新文字由同 turn 最大 revision 得出，sequence 不是对话顺序。

## 客户端确认队列

新独立账号作用域 journal 接收已通过 ConversationProjection 校验且实际 applied 的最终 TranscriptUpdate；临时字幕和 PlaybackUpdate 不提交。每个入队事件只生成一次 event_id/sequence；不合并/替换未确认事件。pending 最多64条且文字总量256KiB，生命周期最多512条/1MiB/256turn；满额记明确缺口/错误，不伪装为已保存。单次最多4条，独立 HTTP fork，总截止8秒（含CSRF），精确验证ACK全部身份、顺序和预算后才移除。不自动重试失败，明确 retryPending 重发同一事件。请求超时可能已提交；精确重放可消歧。

媒体协调器在原通道/账号/租约保护后调用 journal，暴露 pending/rejected/error；普通 stop 封存输入并尽力排空，失败仍可在当前实例显式重试。销毁或账号变化同步 abort 清空、关闭正在请求；晚响应不得恢复。队列仅内存，不宣称跨进程可靠或已完成服务端固化；已持久记录可通过GET读取，后续另接历史UI。现有默认协议/准入关闭不变。

## 验证

先写失败测试，再实现：数据库实际追加/重放/修订/冲突原子性、并发、容量与UTF-8、历史绑定/删除/身份锁等待/CSRF、分页和body超限/超时；Flutter 队列精确确认、失败保留与相同重放、错误ACK/身份变化/截止/容量和媒体仅提交最终 applied 更新。全套后端、Flutter、Node、分析、Web构建及字体检查；独立代码审查；开发数据库升级前后只读核对，不写练习假数据。
