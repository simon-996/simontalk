# 受限媒体观测

日期：2026-10-17，基线7751eb3。持续授权内推进；实际模型、预算、硬件与原生任务暂缓，无推送或部署。

## 选择与范围

现有媒体控制器仅保留最后一条本地code。只加日志无法恢复；由客户端报告直接推进ready/confirmed会混淆证据。采用独立追加的client_observed事实及受限查询，全部连接/练习状态、租约和终止证据保持不变。本批不做恢复页面或供应商事件解析。

## 服务端契约

POST `/v1/practice-sessions/{sid}/connections/{cid}/observations`接收client_instance_id、严格正epoch及1–16条events。每条event_id(UUID)、sequence(严格正32位整数)、code(12项枚举)、elapsed_ms(严格0–86400000)、可选reason(仅local_closed的8项分类)。不接受文本、音频、SDP、任意URL、模型配置、费用或终止声明。实际接收最多8KiB/5秒，沿用现有分块接收保护及Web Origin/CSRF/X-Account-ID。

code为requesting_microphone、negotiating、transport_connected、configuration_confirmed、microphone_active、playback_waiting、playback_blocked、playback_playing、playback_paused、muted、unmuted、local_closed。reason为user_stop、background、disposed、account_changed、lease_expired、connection_failed、configuration_failed、other；非关闭事件不允许reason。

按User→Practice→Connection锁顺序、等待User锁后重验登录；核对所有权及原连接的客户端/epoch。不依赖新连接准入或供应商网关。历史/已关闭连接可追加属于自己的迟到事实，但仅写原连接子表，绝不改变新代次或释放占用。received_at为服务器时间；elapsed_ms是未受信任的客户端相对时间，不参与租约或计费。

同连接event_id及sequence各自唯一。相同event_id且完整摘要一致可重放；改内容/复用sequence为409 observation_conflict。批内sequence递增、event_id唯一；新sequence必须高于已有最大值，允许缺口，旧的未见事件409 observation_sequence_stale。整批先校验再提交，冲突/超限无部分写入。每连接最多256条，新增超限429 observation_limit_reached，完整重放不占额度。

输出固定source=client_observed、连接/客户端/epoch、按请求顺序的acknowledged_event_ids及当前last_sequence/total_events。数据库复合外键绑定连接/客户端/epoch；只存枚举、整数、摘要与接收时间，删除连接级联。GET同路径支持after_sequence和1–32的limit，以单查询的有界记录快照分页，返回原连接身份、事件及next_after_sequence/has_more；当前准入关闭时仍可读取本人历史。

## 客户端与媒体组合

新增一次性journal，绑定同一账号/连接/客户端/epoch，安全随机event_id及递增sequence。64条内存队列、16条串行批次，不持久化浏览器存储。失败暂停自动发送，明确retryPending复用原事件和序号；无自动重试。满队列不丢弃在途批次，新普通事件丢弃计数，local_closed可替换未发送尾项；缺口如实保留。服务端256上限不代表完整记录，不能声称零丢失。

每批派生独立ApiClient/http.Client，动态跟随源账号，覆盖CSRF/凭证等待的8秒总上限；成功、失败、取消均关闭自己的客户端，共享账号API继续可用。确认响应身份和完整event_id集合后才移除队列。finish不再接受新事件、异步发送剩余队列；abort立即取消当前批次并清空本地队列。账号改变后不发送旧数据；错误只保留稳定码。

媒体控制器在登记后建立journal；工厂/上报失败不阻塞建连、续租或同步本地释放。传输连接/协议确认/activate成功分别产生对应本地事实；播放和显式静音独立记录。停止先释放媒体，再记录一次local_closed并finish；账号已变则abort。provider销毁后的收尾仅为有界尽力上报，进程退出不能保证送达。默认503不会创建journal；生产无测试替身，仍没有练习页。

## 验证

PostgreSQL测试覆盖认证/所有权/客户端/代次、严格枚举/体积、重放/冲突/缺口/并发、256上限、事务原子性/锁后撤销、历史事件不覆盖新连接、unknown不释放、级联及分页。客户端覆盖串行/原批重试、上报失败不影响媒体、队列边界/关闭保留、账号切换/响应身份/8秒总截止与独立HTTP所有权；组合真实journal、ApiClient及HTTP替身。完成后全量检查、添加性迁移、本地HTTP边界验证和独立审查。
