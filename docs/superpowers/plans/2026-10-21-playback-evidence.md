# Playback Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 把已应用的播放/首次冻结/撤销事实接入原连接持久账本、严格确认队列和不可变分页读取。

**Architecture:** 独立playback-evidence账本，不改transcripts的AI播放unknown；后端串行原scope追加，客户端自含版本事件避免跨ACK依赖。controller/providers将两种pending归属原账号，真实协议仍Unavailable。

**Tech Stack:** FastAPI/Pydantic、PostgreSQL17/SQLAlchemy/Alembic；Flutter/Dart、http、Riverpod、flutter_test。

---

### Task 1: 后端账本及交叉一致性

**Files:** 新建`services/api/src/simontalk_api/playback_evidence.py`、`playback_routes.py`、Alembic迁移及`services/api/tests/test_playback_evidence.py`；修改models/main/body-limit/final_transcripts/pyproject。

- [x] 先写原连接POST/GET测试：`client.post(path(..., '/playback-evidence'), json={...}).status_code == 200`，运行`uv run --locked --no-sync pytest -q tests/test_playback_evidence.py`确认端口缺失失败。
- [x] 严格实现设计的3种event、显式表约束、原身份锁序、精确eventID重放与原子批次。GET返回`sealed=False, recoverable=False`；ACK固定source及原IDs/累计generated+played字节。
- [x] 追加跨final双向验证；同version源与播放单调、freeze固定、revoke终态，验证普通512满额仍可写撤销槽、总容量/跨账号/CSRF/撤销并发/级联/准备清理不变。
- [x] 新增512KiB/5秒middleware分块测试，运行新API/迁移metadata测试和ruff；迁移仅独立测试库先升级。

### Task 2: 客户端自含事件与确认/读取

**Files:** 新建`apps/client/lib/features/conversation/playback_evidence_models.dart`、`playback_evidence_journal.dart`、`playback_evidence_read_models.dart`及对应测试。

- [x] 先写snapshot/ledger、缺少journal端口的失败用例，运行`flutter test --no-pub test/features/conversation/playback_evidence_read_test.dart test/features/conversation/playback_evidence_journal_test.dart`确认缺行为。
- [x] 实现`recordAlignment(turn)`、`recordFreeze(turn,stopBoundaryMs:,reason:)`、`recordRevoke(responseId)`，稳定eventID、独立revoke槽、原scope fork、8秒截止、严格ACK、显式retry、finish/abort和通知/正文释放。
- [x] 实现每页16的严格parse与不可变history，跨页同version/身份/映射冲突原子拒绝，保留旧版本前缀及迟到revoke；固定未封存/不可自动恢复状态。
- [x] 运行models/journal/read新测试及原conversation回归，覆盖字符串/布尔整型、Unicode/容量、响应字段/IDs/bytes、未知丢ACK重放、时钟晚回调与账号变更。

### Task 3: 媒体、账号归属和仓库接入

**Files:** 修改`practice_media_controller.dart`、`practice_media_providers.dart`、`practice_repository.dart`；新建`apps/client/test/features/realtime/practice_media_playback_evidence_test.dart`，扩展provider/repository测试。

- [x] 先写测试：普通生成不记录，applied PlaybackUpdate只记录一次；首次freeze抓原版本，晚final不覆盖旧prefix，applied revoke入队后即使stop仍finish；错误不误释放/泄露。运行新测试观察缺端口失败。
- [x] 接入可选PlaybackEvidenceJournalFactory；guard前后保留原账号/通道/epoch和截止；仅applied事实采集，stop finish、身份/dispose abort。只读GET绑定原ConnectionReservation并核对scope。
- [x] provider默认装配真实journal，同时监听两种队列，任一pending保留，无监听且关闭/全确认释放；账号切换同步清空。验证无副作用构造、失败/重入及离页状态。

### Task 4: 真实链路、复核与交接

- [x] 临时loopback API使用独立simontalk_test、测试准入和Unavailable供应商，真实Dart HTTP提交alignment→freeze→晚新版本→revoke并分页重建；核对精确ACK、其他账号404、原transcripts仍unknown、连接/租约/终止不变。清理临时凭证/数据/服务。
- [x] 独立规格审查后修复并复审，再独立代码质量审查；保留失败回归证据。
- [x] 运行API全套、ruff check/format、Alembic head/metadata/check、Flutter完整测试/analyze/97文件格式、Node全套与Web release/no-pub/本地资源构建及字体校验，锁文件不变。
- [x] 新建验证报告，同步相关契约/HANDOFF当前状态与下一步；保留进入本单元前所有未提交改动，不推送/部署，不调用供应商或恢复原生构建。

执行结果：API344、Flutter534通过/需隔离夹具1项默认跳过，独立真实HTTP1、Node58、分析/97格式、Web40.8秒和完整字体通过；迁移及独立规格/质量复核通过，原有工作保留。实际证据、失败回归及未实现边界见[验证报告](../../development/2026-10-21-playback-evidence-verification.md)。
