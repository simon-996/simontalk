# 练习准备登记实施计划

> **For agentic workers:** 使用superpowers:executing-plans，在现有功能分支按用户持续推进授权执行；不调用供应商。

**Goal:** 持久保存练习准备的所有权、快照与幂等性，并保持真实语音默认关闭。

**Architecture:** FastAPI独立练习router调用小型登记用例；PostgreSQL用户行锁与部分唯一索引限制并发。准入接口真实实现关闭，测试替身仅进入独立测试库；取消只适用于未建连状态。

**Tech Stack:** 现有FastAPI、SQLAlchemy、PostgreSQL17、Alembic、pytest。

## 执行

- [x] 先写`services/api/tests/test_practice_preparation.py`验证契约中的拒绝无写入、幂等、快照、隔离、取消、并发与Web保护；运行确认当前404失败。
- [x] 在`models.py`增加PracticeSession与索引，新增Alembic迁移；把共享database_session依赖移至db.py，旧router继续导入。
- [x] 新增`practice.py`准入类型、默认拒绝与登记/读取/取消用例，`practice_routes.py`接入身份/CSRF；main注册router和默认关闭策略，CORS仅新增Idempotency-Key允许头。
- [x] 定向测试通过后运行后端完整测试、Ruff/format与Alembic迁移检查，验证数据库并发限制及持久重放。迁移仅新增表，不改账号数据。
- [x] 独立复核竞态与身份隔离，更新契约、运行说明/交接及验证记录；本地提交，继续可执行准备任务。前端不增加无真实语音的开始按钮。

完成证据见`docs/development/2026-10-17-practice-preparation-verification.md`；默认策略仍关闭，无付费调用；本地HTTP503无写入已验证。
