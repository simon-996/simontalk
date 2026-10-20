# 最终文字持久提交 Implementation Plan

> **For agentic workers:** 使用 superpowers:subagent-driven-development 分离后端、客户端实施与独立审查。按当前持续开发授权直接执行。

**Goal:** 建立账号/原连接绑定的最终文字修订追加、读取与精确确认队列。

**Architecture:** 后端沿用受限观测的锁、所有权和复合外键模式，单独保存最终文字；客户端独立 journal，媒体只提交已接受的最终修订。播放与练习业务状态不受提交影响。

**Tech Stack:** FastAPI、Pydantic、SQLAlchemy、PostgreSQL17、Alembic；Flutter/Dart/http。

---

## 1. 后端持久记录与HTTP

- [x] `services/api/tests/test_final_transcripts.py` 先测试 POST 新增成功和精确重放，再运行预期404失败；补充冲突/修订/原子性/容量/历史/身份/分页与数据库约束测试。
- [x] 新建 `final_transcripts.py`（受限schema、追加/查询）、`transcript_routes.py`（认证与路由）、Alembic迁移；修改 `models.py`、`main.py`、`offer_body_limit.py` 与ruff路由配置。具体字段和界限严格按[设计](../specs/2026-10-20-final-transcript-storage-design.md)。核心事务顺序：`own_preparation(lock=True)` → `own_connection(lock=True)` → 核验全部event → `add_all` → `commit`；精确重放先于预算检查。
- [x] `uv run pytest -q tests/test_final_transcripts.py tests/test_offer_body_limit.py` 通过，再全套 pytest/Ruff/迁移 roundtrip/check。

## 2. 客户端队列及媒体接入

- [x] 新建 `apps/client/test/features/conversation/final_transcript_journal_test.dart`，用真实ApiClient+MockClient测试失败保留、同ID重放、严格ACK；先运行缺失实现失败。
- [x] 新建 `apps/client/lib/features/conversation/final_transcript_journal.dart`：`RealtimeTranscriptJournal`接口、factory typedef与实现。复用ApiClient账号fork/CSRF，序列化4条批次、8秒总截止，显式重试，输入finish/abort及统计字段。契约见设计，不复制原始事件、不自动重放。
- [x] 修改 `practice_media_controller.dart`，新增可注入 transcriptJournalFactory 与统计getter；连接分配后创建；`_acceptConversation` 中 projection applied 且最终 TranscriptUpdate 时record；stop/账号变化/dispose按设计finish/abort。
- [x] 扩展媒体组合测试，覆盖临时不提交、最终修订仅一次、播放不提交、正常停止/账号变化。执行目标测试、全套Flutter、analyze和format。

## 3. 审查与交接

- [x] 独立审查设计符合性和代码质量，修复确定问题后复验。
- [x] 顺序执行 Flutter Web release、字体校验；Node传输测试。后端源码重启本地API后验证ready，核对开发库无新增练习/文字。
- [x] 更新架构契约、技术设计、本地开发、验证报告、HANDOFF；运行git diff --check，按已授权本地提交，不推送/部署。

命令：后端在 `services/api` 运行 `uv run pytest -q`、`uv run ruff check .`、`uv run ruff format --check .`、`uv run alembic check`。客户端在 `apps/client` 运行 `flutter test`、`flutter analyze`、`dart format --output=none --set-exit-if-changed lib test`、`flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000`；Node/字体命令以仓库本地开发记录为准。先验证独立测试库迁移，再升级开发库；禁止在开发库运行pytest或种入假练习。
