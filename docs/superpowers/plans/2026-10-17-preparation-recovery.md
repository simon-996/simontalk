# Preparation Recovery Implementation Plan

> 使用superpowers:executing-plans在现有功能分支内执行，保留工作区；按持续开发授权不再询问常规工程选择，完成后依requesting-code-review派发独立只读复核。

**Goal:** 本人登记只读恢复、有界准备清理及API内自动调度。

**Architecture:** recovery查询使用单条SQL；preparation_cleanup负责资格与锁后复查，practice_maintenance负责单批事务/线程调度；现有连接到期逻辑复用。Flutter只增加只读模型和仓库方法。

**Tech Stack:** FastAPI、SQLAlchemy/PostgreSQL17、Alembic、threading/asyncio、Dart/http、pytest/flutter_test。

## Task 1: 当前登记

文件：新增`services/api/src/simontalk_api/practice_recovery.py`及`tests/test_preparation_recovery.py`，修改`practice_routes.py`；客户端修改practice_models/repository和对应测试。

- [x] 测试GET `/v1/practice-sessions/current`空结果200/本人准备/最新连接/未知占用优先/匿名401，先观察现有动态UUID路径422失败。
- [x] 实现`current_preparation(db,user_id)`，单次SELECT联查本人未终结练习或占用连接，返回`{practice,connection}`；静态路由先于UUID路由注册。不得调用admission或写数据库。
- [x] 先写客户端GET及不一致归属测试，再添加`PracticeRecovery.fromJson`和`loadCurrentPreparation()`；没有创建键持久存储或自动控制。

## Task 2: 保守清理

文件：新增`services/api/src/simontalk_api/preparation_cleanup.py`，修改models/practice及添加Alembic迁移。

- [x] 先测300秒资格边界、安全已结束连接的最近时间、未知/历史上游/非created保护、旧key重放终态；再实现`expire_idle_preparations(db,limit=100)`。
- [x] 为PracticeSession添加nullable state_reason及created_at/id部分索引，PracticeOutput与Dart模型返回原因。主动取消写cancelled_before_signalling，自动清理写preparation_expired。
- [x] 候选有界并排序；User→Practice skip_locked，锁后重新查询created/cutoff与全部连接证据。用真实事务测试候选后新建/取消连接不能被旧结果覆盖。

## Task 3: 自动调度

文件：新增`practice_maintenance.py`和`tests/test_practice_maintenance.py`；修改main/config/cli与.env.example。

- [x] 先测单批连接+准备回收和事务本地超时；实现`run_maintenance_batch(factory,limit)`，每批提交，失败完整回滚。
- [x] 线程使用独立连接池、Event.wait间隔、错误后继续、固定日志、停止事件及有界join；测试重复启动保护、失败恢复、线程停止后无新批次。
- [x] FastAPI lifespan启动/停止runner，默认15秒，可配置间隔；测试实际lifespan自动清理，无test-only准入接入生产。
- [x] 新增CLI `cleanup-preparations --limit 100`复用批次并在提交后打印计数；测试真实子进程及参数边界。

## Task 4: 验证和交接

- [x] `uv run pytest -q`、`ruff check/format`、Alembic upgrade/check；Flutter全量/分析/格式、Node51项、Web release与发布字体校验。
- [x] 独立只读复核，重要问题先复现再修复；开发库添加性迁移、重启API，实际HTTP匿名401/readiness与维护零条分开记录。
- [x] 更新API/开发说明、验证报告与HANDOFF，核对阶段和边界；本地提交，不推送或部署。

验证与剩余边界见[恢复和清理验证](../../development/2026-10-17-preparation-recovery-verification.md)。
