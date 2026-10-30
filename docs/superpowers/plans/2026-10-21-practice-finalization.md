# Practice Finalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 将正常end接入服务端固定补交窗口、真实覆盖核验及不可变输入固化，同时保留未知媒体占用。

**Architecture:** 原连接end意图、drain后不可变事件manifest、两个追加门与持久maintenance固化。客户端独立无正文提交清单和completion client，不阻塞媒体释放；服务器输入固定不等于可信上游终止。

**Tech Stack:** FastAPI/Pydantic、SQLAlchemy/PostgreSQL17/Alembic、Flutter/Dart/http/Riverpod。

---

执行[详细设计](../specs/2026-10-21-practice-finalization-design.md)的完整wire和字段；保留工作区已有全部改动，原有feature分支复用，不提交/推送/部署。

### Task 1: 服务端固定窗口、清单、固化与占用

**Files:** 新建`services/api/src/simontalk_api/practice_completion.py`、`completion_routes.py`、`termination_checks.py`和Alembic迁移/`tests/test_practice_completion.py`；修改models/main/body-limit、两个账本、connections/signalling/maintenance及相应测试。

- [x] 先新增端口失败用例并运行`uv run --locked --no-sync pytest -q tests/test_practice_completion.py`：`assert client.post(path(..., '/end'), headers={..., 'Idempotency-Key': str(uuid4())}, json=control).status_code == 200`应先因404失败。
- [x] 实现设计三个表、唯一/外键/状态检查及接口：`begin_completion(db,user_id,sid,cid,payload,key)`固定30秒；`submit_manifest(...)`规范化精确重放，`read_completion(...)`纯读；同一连接锁内原子登记blocked核验意图。
- [x] 两追加接口在每个新事件前调用`validate_completion_append(db,practice,connection,ledger,event,stamp)`，精确已存digest先确认；新事件截止/seal统一409，清单后限制ID/seq，混合批次回滚。
- [x] `try_finalize_completion(...)`核对全历史成员清单/实际集合及bytes，保存版本1 snapshots/hash/资格和前缀引用；`finalize_due_completions(db,limit=...)`接原维护runner，保护ending/completed父状态，禁止续租/新offer，未知占用不变。
- [x] RED/GREEN覆盖固定key/deadline、跨账号/CSRF/锁后身份、并发/混合原子、历史scope、空final/原freeze/revoke、断开父状态保护/重启扫描/终止任务去重和级联。运行目标测试及ruff/迁移；先只升级独立测试库，勿与root实际HTTP并行清库。

### Task 2: 无正文manifest、严格summary与HTTP completion client

**Files:** 新建`apps/client/lib/features/practice/submission_manifest.dart`、`practice_completion_models.dart`、`practice_completion_client.dart`和对应测试；修改两journal、practice_repository、playback读取模型/测试。

- [x] 先写失败用例：ACK之后`(journal as SubmissionManifestProvider).submissionManifest!.events`仍含全部原ID，`abort()`后为null；摘要错误scope/hash/revision/deadline关系须拒绝。运行`flutter test --no-pub test/features/practice/practice_completion_test.dart`观察缺端口失败。
- [x] 实现不可变SubmissionEventRef/SubmissionManifest和独立provider接口，生产journal成功入队才保存header refs，不保存第二份正文；ACK/finish保留，abort同步清空。普通/播放数量字节上限同设计。
- [x] 严格summary和最终manifest模型；仓库增加原连接end/manifest及只读summary。completion client提供`requestEnd()/finish(manifest)/retryPending()/refresh()/abort()`及Listenable/errorCode/hasPendingWork；稳定key/body，原账号fork8秒含CSRF，end后串行manifest，明确失败暂停，等待固化只读有界轮询。
- [x] playback page/history接sealed bool，允许false→true，seal后水位/统计/事件固定，recoverable=false。运行新models/journal/coordinator/repository测试及原conversation回归；不改controller/providers（root接入）。

### Task 3: 媒体与账号留存接入

**Files:** `practice_media_controller.dart`、`practice_media_providers.dart`、新建`test/features/realtime/practice_media_completion_test.dart`。

- [x] 先写RED：正常end同步停止媒体、pending completion不延长3秒；beginDrain抛错仍登记意图；空TurnStarted出现在unfinalized清单，late sync final计入journal refs；provider空队列离页仍保留待确认end。
- [x] scope建立后创建可选factory并安全监听；end安排仅异步意图，再同步停麦；stop清集合前采集缺口，finish两journal后capture一次固定清单。账号变化/销毁abort，普通未end中断保持旧语义；completion成功不改releaseStatus。
- [x] provider默认真实HTTP工厂并将hasPendingWork纳入keepAlive，sealed receipt核对且两queue确认或明确结清缺失后释放；新增重入/失败/账号/离页测试并复验原drain/provider行为。

### Task 4: 真实链路、复核与交接

- [x] 独立临时API+simontalk_test，真实Dart两journal与completion client提交end→manifest→迟到pending→seal；另验证无manifest到期固化/新事件拒绝、精确重放、B账号隔离及unknown占用仍存在。临时凭证/账号/邀请/服务精确清理。
- [x] 独立规格审查修复并复审，再独立质量审查；保存真实失败/修复证据。
- [x] 全量API/Flutter/Node、ruff/格式/analyze、测试库迁移降升/metadata、开发库保留数据升级与默认关闭API重启、Web no-pub/无CDN及完整字体校验。依赖锁文件不变。
- [x] 新验证报告、当前接口契约、技术/交互/验证和HANDOFF同步已实现与剩余边界；本地文档链接/围栏/git diff --check。无模型/原生/推送/部署。

实际结果：API387、Flutter565通过/2项隔离夹具默认skip、独立HTTP1、Node58、分析/103格式、Web35.8秒及字体通过；迁移/metadata、独立规格/质量复核通过，前批改动保留，未提交/推送/部署。实测窗口、回归修复、临时清理及剩余边界见[验证报告](../../development/2026-10-21-practice-finalization-verification.md)。
