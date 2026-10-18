# 当前登记恢复与自动准备清理

日期：2026-10-17。真实语音准入继续固定UnavailableAdmission；此能力只管理持久业务登记，不操作供应商媒体。

## 只读恢复

GET `/v1/practice-sessions/current`需现有认证，客户端同时传X-Account-ID绑定账号；无当前登记返回200 `{"practice":null,"connection":null}`。有占用时返回现有PracticeOutput及可选ConnectionOutput，不返回创建键、凭证或SDP，不写数据库、不重新准入、不续租或分配代次。Cache-Control继续为no-store。

查询通过单条SQL联查本人未终结练习和最新连接；仍占用的连接优先，即使其父练习被错误标记终结，避免隐藏unknown。只读结果是查询时的快照，后续控制仍须服务器重新鉴权、加锁与核对epoch。最新安全终结连接可随仍未终结的练习返回；已终结且没有占用的练习不作为current返回。

Flutter的PracticeRepository.loadCurrentPreparation与PracticeRecovery解析此契约，核对连接归属、公开配置和代次；其他客户端实例可以被看见，读取不转移控制权、不自动接管、续租或取消。2026-10-18已接到偏好页的[只读查看入口](2026-10-18-readonly-recovery-client.md)，按明确操作读取当前登记和原连接观测；没有自动恢复媒体或原创建请求。

## 准备清理资格

每个完整批次先扫描连接45秒业务租约，再扫描created练习。工程采用300秒闲置资格：创建时间已到截止，且全部关联连接均无占用、termination_status=not_started、存在结束时间且结束时间不晚于截止。没有连接的created练习也可清理。

| 事实 | 处理 |
| --- | --- |
| 满足资格的created练习 | cancelled、ended_at、state_reason=preparation_expired |
| 连接刚安全终结 | 再保留300秒，避免旧created_at立即导致取消 |
| 仍有准备/媒体/unknown连接 | 保留占用 |
| 任何历史上游证据，包括confirmed终结 | 本准备清理器不处理，留给正式练习结束流程 |
| 非created练习 | 不修改 |

TTL是后台清理资格，受进程运行、批次数量和锁竞争影响，不能承诺刚到300秒就执行。候选各最多100条，按时间/id排序，锁顺序User→Practice且skip_locked；锁后重新查询完整资格，保护候选产生后的新连接及最近终结活动。所有行、偏好快照和原始幂等键保留，旧key仍返回原终态。主动取消的原因是cancelled_before_signalling；旧数据原因可为null。

## 调度与事务

正常FastAPI lifespan为每API进程启动一条串行后台线程，使用独立数据库连接池。首次及后续批次之间默认等待15秒；`SIMONTALK_PRACTICE_MAINTENANCE_INTERVAL_SECONDS`可设1–300秒。多进程利用同一数据库锁和资格复查协作，不需要独占领导者。每个批次中两种扫描在同一事务提交；任意错误整体回滚，下一间隔重试。

每批局部设置transaction_timeout=5s、statement_timeout=2s、lock_timeout=100ms，不修改全局或其他池事务。PostgreSQL17的事务超时会终止超时连接，SQLAlchemy下次使用需重新连接；语义见[PostgreSQL17连接默认参数](https://www.postgresql.org/docs/17/runtime-config-client.html)。当前本机17.11已实际验证参数支持和事务局部作用域。

停止服务时发送Event并至多等待线程10秒；同步SQL不阻塞请求事件循环。周期失败仅记固定警告，成功有处理时记录提交数量，不记录异常原文、原话或凭证。当前readiness只检测数据库查询，不证明清理循环最近成功；持续故障的运维告警仍待后续。进程关闭或禁用lifespan时不会周期清理，重新启动后继续有界处理积压。

## 管理入口与边界

`simontalk-admin cleanup-preparations --limit 100`执行同一完整批次，limit严格1–1000，提交后输出两类计数；原expire-connections只执行连接扫描。命令依赖本机数据库维护权限，没有远程管理API。

扫描不会调用供应商、结束媒体、退款或确认费用。unknown继续占用。跨刷新原始未知请求的精确重放、持久用户操作恢复、媒体协调器、SDP网关、供应商配置确认和结束证据均不在本批。实测证据见[验证记录](../development/2026-10-17-preparation-recovery-verification.md)。
