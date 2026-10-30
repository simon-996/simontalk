# 人工数据库备份与离线完整性检查

依据既有阶段5、删除恢复契约和连续工程授权，本单元交付实际可运行的本地运维命令。既有人工恢复依赖操作者自行pg_dump，尚无有界生成/文件摘要入口；本单元补这一缺口。暂缓的模型/预算/设备不影响此项。

## 设计选择

使用PostgreSQL17 custom dump与同步快照。官方[pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html)支持--snapshot，导出事务需在工具导入期间保持开启，见[快照同步](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-SNAPSHOT-SYNCHRONIZATION)。不采用两个独立事务分别导出数据/清单（可能跨删除提交）；不引入后台调度或云存储账户。本轮为人工生成、离线检查及隔离恢复实测。

backup-create要求新绝对目录，排他mkdir0700，不覆盖已有目录/文件/链接。目录生成中没有manifest，不可当已完成；database.dump和deletions.json均0600，完成fsync后最后发布manifest.json就绪标记。失败仅删除自己产生的已知文件、移除自己的空目录，不递归清除后来出现的外部文件。无论失败还是中断都不发布成功。

持同一REPEATABLE READ READ ONLY事务，用现有完整删除清单导出逻辑和pg_export_snapshot，再将--snapshot交pg_dump。源schema须当前head，明确PG17；短SQL设statement/lock timeout。pg_dump非shell argv调用、私有显式PG环境，不把URL/密码放argv或日志；默认工具阶段30秒、最大120秒、dump最多512MiB，stdout分块写，stderr只计数不输出，非空警告/失败/超限/超时拒绝，结束清进程组及资源。工具路径仅pg_dump或明确绝对路径；兼容客户端工具由维护者提供。本机实际验证用容器内17工具的临时wrapper，不修改生产依赖。

manifest_v1记录创建UTC、schema revision、PG server_version_num、source_database、两个固定文件的bytes/SHA256和删除清单content_hash。JSON字段、类型、重复key及文件名严格限制；摘要检测损坏，不能认证来源或证明清单最新。当前支持单TCP数据库及明确SSL连接查询字段，其他连接形式拒绝而不静默换配置。

backup-check只读本地目录，无Settings/数据库/子进程。拒相对路径、符号链接、非私有权限、非普通文件、超限/缺件/未知文件/类型或hash不符；同FD检查/读取，校验删除清单原语义与dump基本header。返回integrity_verified:true、restore_verified:false、latest_deletions_verified:false。检查hash不等于实际恢复通过，不能执行未知来源dump。

## 恢复与边界

实际测试以真实pg_dump/pg_restore恢复独立数据库，再对比原快照全行业务摘要；并发删除在snapshot后提交时，备份应保持原快照，恢复后必须额外重放最新删除清单，正文不复活且unknown占用保留。备份内清单只覆盖备份快照，不能替代最新权威清单。沿用停服/隔离/明确预检及apply的人工恢复约束。

没有自动备份计划、异地实时删除日志、自动保留期或发布配置，也不声称阶段5整体完成。source schema/业务数据不变，锁/客户端不变；实际产物仅临时合成测试库，用后清理，不生成真实开发账号的持久备份。
