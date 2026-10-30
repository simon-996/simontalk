# 备份生成与离线核验实施计划

> 内联按executing-plans/TDD完成；用户已授权连续工程，保留原工作，不提交/推送/部署。

**Goal:** 可直接运维使用的backup-create/backup-check，含同快照删除清单和受限pg_dump。

**Architecture:** 新backup_bundle.py负责私有文件、schema manifest、工具和快照；deletion_archive.py提取同session只读导出以复用完整验证；cli.py仅新增分发，离线check在建DB前执行。

**Tech Stack:** 既有Python3.13/SQLAlchemy/PostgreSQL17/Pydantic，stdlib subprocess/selectors，无新增Python依赖。[设计](../specs/2026-10-25-backup-bundle-design.md)。

## 1 文件与工具边界

- [x] 新`services/api/tests/test_backup_bundle.py`先断言模块/离线检查入口缺失，再写私有目录/文件、严格manifest/摘要/重复字段/损坏/链接、既有目标拒绝用例；命令`uv run --locked --no-sync pytest -q tests/test_backup_bundle.py`先RED。
- [x] 新`services/api/src/simontalk_api/backup_bundle.py`实现BackupError、固定database.dump/deletions.json/manifest.json、同FD权限/大小/摘要检查。只认manifest就绪；无DB的check只给完整性结果。
- [x] 写本地可信假工具子进程：正常PGDMP、错误/警告、卡住、输出超限、敏感stderr；先RED后实现分块/截止/清理/脱敏。PG密码仅显式环境、无shell。

## 2 同快照与CLI

- [x] 在`deletion_archive.py`提取`export_deletions_in_snapshot(db)`，要求repeatable read/read only；旧`export_deletions(factory)`保持原事务与完整性语义，跑原目标。
- [x] create_backup持原SQL快照，导出清单及pg_export_snapshot，调用有界pg_dump，完成后发布manifest；失败清自己文件，不动已有目标或并发加入文件。
- [x] 新`services/api/tests/test_backup_bundle_integration.py`覆盖真实SQL零写、权限/失败/源schema拒绝及新CLI两个入口；离线check monkeypatch数据库创建为失败也应正常运行。
- [x] cli增加`backup-create --output ABS --pg-dump ... --timeout-seconds 1..120`和`backup-check --input ABS`，错误只输出稳定code，check不初始化Settings/engine。

## 3 实际工具与恢复

- [x] 本轮专属*_test库及私有wrapper，实际容器PostgreSQL17 pg_dump生成，独立pg_restore恢复后核快照全行；并发删除在快照后提交的备份仍为原快照，最新删除清单重放后内容清零/unknown保留。
- [x] 目标/全量API、Ruff/格式/锁/metadata、wheel/runtime核验；保留开发库20业务表及迁移记录全行摘要，清理专属库/私有备份/脚本。
- [x] 独立只读复核限定变更，确定问题先RED再修；更新契约/本地运行/HANDOFF/验收，区分完整性校验、实际恢复、最新删除与未实施的自动异地/保留期。

最终新增54项，目标82/24.62秒，全量975/189.45秒；Ruff/106格式/38包锁/metadata、wheel/runtime真实备份恢复及开发21表全行保留通过。独立审查三轮，确定清理问题均先RED后修正；完整证据见[验证](../../development/2026-10-25-backup-bundle-verification.md)。
