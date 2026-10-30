# 删除清单与离线重放实施计划

> 使用superpowers:executing-plans及test-driven-development逐步执行。保留当前含前置改动分支，不提交/推送/部署，不改Flutter或依赖。

**Goal:** 运维可以独立保存无正文删除决定，并在旧库恢复后预检/原子重放，防止已删正文重新开放。

**Architecture:** 严格有界JSON清单；只读统一快照导出；按owner锁及时间顺序预检，复用B4正文清除，原凭据和安全占用保留。接入既有simontalk-admin，不增加HTTP管理端口。

**Tech Stack:** 现有Python/SQLAlchemy/PostgreSQL/Pydantic/标准库；[规格](../specs/2026-10-23-deletion-restore-design.md)。

## 1. 导出及文件完整性

- [x] 在`services/api/tests/test_deletion_archive.py`先写真实删除后导出、无正文/零写、损坏/重复/界限拒绝和私有文件/不覆盖测试，观察缺模块RED。
- [x] 新增`src/simontalk_api/deletion_archive.py`：Member/Entry/Archive模型、canonical摘要、严格JSON读取及原子0600/fsync文件写入。
- [x] 实现`export_deletions(factory)`：REPEATABLE READ READ ONLY、核对head、全部receipt持久成员→原scope hash/全部现有墓碑覆盖与已有成员一致性，返回归一化清单，不提交业务变化。
- [x] 持久保存完整成员，移除receipt owner FK以覆盖旧备份缺账号；迁移回填核对原范围hash、计数并拒绝非空降级。补缺成员/账号恢复→再次导出→另一备份重放回归。

## 2. 预检与重放

- [x] 先写旧数据恢复后dry-run不变/明确apply清正文/重复全行不变、缺成员/账号不复活、额外子或owner/原凭据冲突零半写、unknown及用量保留测试，观察功能缺失RED。
- [x] 从`practice_deletion.py`提取`purge_practice_content(db,user_id,members,stamp)`，保留现有DELETE事务/凭据行为；用原17项删除及worker回归核对。
- [x] 在`deletion_restore.py`实现`replay_deletions(factory,archive,apply=False,confirm_database=None)`：全批owner锁→成员/原凭据→模拟可见性→明确apply同事务清除/原凭据，预检rollback、冲突全批无写。

## 3. 正式运维入口

- [x] `cli.py`增加export/replay参数和无正文摘要输出；默认预检，apply字面核对目标数据库，异常不输出URI/正文。
- [x] CLI测试环境隔离Settings，验证无apply零写、目标不匹配拒绝、导出文件已有不覆盖与失败输出不含秘密。
- [x] Ruff/格式、目标到API全量及原删除回归；独立审查仅只读，不并行使用共享测试库。

## 4. 实际恢复演练与交接

- [x] 专属源/恢复测试库：真实pg_dump、实际父/单子删除、独立清单、pg_restore、命令预检/明确重放、HTTP隔离/旧文字404、unknown仍409及二次重放全行不变。
- [x] 只读核对开发20表全行/head/依赖保留；精确清理专属库、私有备份/清单/凭证/脚本/API进程。
- [x] 更新HANDOFF、B4后续边界、运维手册/技术/验证和实际报告；不标自动备份、独立日志持续性、可信媒体终止或完整基础版本已完成。

最终证据：[验证报告](../../development/2026-10-23-deletion-restore-verification.md)。API709、目标45、迁移与真实完整/缺成员备份恢复、缺账号再导出及HTTP通过，独立复审无确定问题。依赖/Flutter不变；开发20表全行不变，schema升级4f6a58cd2e32。
