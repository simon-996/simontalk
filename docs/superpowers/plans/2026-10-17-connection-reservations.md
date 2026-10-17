# Connection Reservations Implementation Plan

> 使用executing-plans在现有干净功能分支内执行；沿用户持续开发授权，不再次询问常规工程选择。独立复核按requesting-code-review派发只读审查。

**Goal:** 实现持久连接准备、单调代次、幂等/并发保护及不冒充上游终止的业务租约。

**Architecture:** PostgreSQL模型/迁移保存尝试；独立connections用例与路由复用账号保护；CLI调用同一到期扫描。真实准入固定关闭。

**Tech Stack:** FastAPI、Pydantic、SQLAlchemy、PostgreSQL17、Alembic、pytest。

## Task 1: 数据与登记

- [x] 新建`tests/test_connection_reservations.py`，以现有TestAdmission只在测试库建立准备；默认连接请求应503无写入，先观察现有404失败。
- [x] `models.py`添加父epoch/复合唯一键、RealtimeConnection与外键/唯一/状态约束；新Alembic迁移显式定义同一schema。
- [x] 新建`connections.py`与`connection_routes.py`，实现创建/详情、payload和output；`main.py`注册路由。创建只在当前permit与原快照匹配时分配epoch。
- [x] 测试同key/不同key并发、持久重放、所有权、epoch/配置/输入与数据库约束。

## Task 2: 租约与取消

- [x] 先写续租截止边界、旧epoch/client、取消幂等和非preparing不可取消测试，再实现`renew-lease`与`cancel-preparation`。
- [x] 准备登记/取消增加连接占用保护，避免未知连接被错误父状态绕过。
- [x] 新建扫描用例，锁顺序User→Practice→Connection且skip_locked；先测not_started安全失败、未知占用保留、重复扫描、并发续租后重查。
- [x] CLI增加`expire-connections --limit`，实际子进程验证；只输出数量，不输出原话、凭证或上游内容。

## Task 3: 集成与证据

- [x] 定向与全量pytest、Ruff、格式、Alembic check/迁移检查通过；独立复核并处理重要问题。
- [x] 开发库应用添加性迁移，重启本轮API后验证默认HTTP拒绝且不写连接；不调用供应商、不增测试练习。
- [x] 更新契约/本地开发/HANDOFF/验证报告；本地提交并保留当前分支，不推送/部署。

验证结果见[连接准备与租约验证记录](../../development/2026-10-17-connection-reservations-verification.md)。
