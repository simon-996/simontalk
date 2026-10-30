# 人工备份包与离线完整性检查

本单元补齐阶段5的人工备份生成入口。生产实现为`backup_bundle.py`，复用既有删除清单验证及运维CLI，无新依赖、迁移或后台任务。[设计](../superpowers/specs/2026-10-25-backup-bundle-design.md)、[验证](../development/2026-10-25-backup-bundle-verification.md)。

## 命令与文件

在`services/api`运行，`backup-create`读取当前Settings数据库地址：

```sh
uv run --locked --no-sync simontalk-admin backup-create --output /absolute/private/backup-20261025 --pg-dump /absolute/tools/pg_dump --timeout-seconds 30
uv run --locked --no-sync simontalk-admin backup-check --input /absolute/private/backup-20261025
```

默认工具名为`pg_dump`，也接受明确绝对路径。工具需由维护者提供；当前支持POSIX、PostgreSQL17及schema `4f6a58cd2e32`。支持单TCP数据库及显式`sslmode/sslrootcert/sslcert/sslkey/channel_binding`，不支持的URL参数拒绝执行，不沿用PGSERVICE/PGOPTIONS/用户pgpass配置。Python包不包含PostgreSQL客户端。

创建目标必须是尚不存在的绝对目录，父目录须已存在。排他创建目录0700，固定三个0600文件：

| 文件 | 内容与发布顺序 |
| --- | --- |
| `deletions.json` | 原有`deletion_archive_v1`完整清单，无被删正文 |
| `database.dump` | PostgreSQL custom dump；含该快照内数据库业务内容，应私有保管 |
| `manifest.json` | 最后写入并同步；缺少它的目录不可视为已就绪 |

manifest固定`backup_bundle_v1`，记录有时区创建时间、schema、PG版本、源库名、两个文件的字节数/SHA256及删除清单语义hash。不记录数据库URL、密码、原话或工具stderr。成功JSON含`created:true`；错误只输出稳定code。已有目录/文件/链接均不覆盖，失败只清理自身创建的文件，保留外部新增或替换的文件，不递归删除目录。

## 快照与工具边界

源连接开启REPEATABLE READ READ ONLY事务，SQL statement/lock分别限制5秒/2秒，校验当前schema与PG17后，在同session导出删除清单及`pg_export_snapshot()`；`pg_dump --snapshot=...`运行期间保持事务开启。这样备份与清单看到同一快照，工具期间提交的删除不会只进入其中一份。依据官方[pg_dump说明](https://www.postgresql.org/docs/17/app-pgdump.html)与[快照同步说明](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-SNAPSHOT-SYNCHRONIZATION)。这不是停止业务写入的命令。

工具通过无shell argv调用，密码只交显式进程环境，不放URL或argv。stdout流式写入，上限512MiB；删除清单上限32MiB，manifest上限64KiB。工具阶段默认30秒、可选1–120秒；超时、超限、非零退出、任何stderr或坏header均拒绝，清理整个进程组，包括leader已退出的情形。此期限不等于含连接、导出和磁盘同步在内的全命令总耗时。

## 离线检查与恢复

`backup-check`不读取Settings、不建engine、不连接数据库、不启动子进程。检查固定文件集合、当前用户所有权、私有权限、非链接普通文件、严格JSON字段/类型/重复key、大小与摘要、`PGDMP`基本header和删除清单完整语义；通过同一FD检查与读取。

通过时明确返回`integrity_verified:true`、`restore_verified:false`、`latest_deletions_verified:false`。摘要可发现损坏，不能认证来源；header和hash也不能证明dump能够恢复。实际恢复须使用可信来源备份，在隔离数据库以`pg_restore --exit-on-error --no-owner --no-acl`执行，核对schema及业务内容。CLI不自动执行恢复。

备份内清单只覆盖备份时刻，不能代替恢复时可信的最新权威清单。沿用[人工停服恢复流程](2026-10-23-deletion-restore.md)：先停止服务与写入、独立保管最新完整删除清单，恢复旧快照、迁移、默认零写预检、明确目标库后原子重放、再验旧正文不可读/其他账号保留/unknown仍占用，验收后才恢复服务。

本轮没有实现调度、异地实时清单、远端存储、自动保留期执行或生产恢复切换。7天备份/14天清单仍是既有建议参数；这里不开始自动删除任何备份，也不宣称阶段5整体完成。
