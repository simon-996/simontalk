# 人工备份生成与离线核验验证

日期：2026-10-25，Asia/Shanghai。范围为阶段5的人工备份单元；[契约](../architecture/2026-10-25-backup-bundle.md)、[设计](../superpowers/specs/2026-10-25-backup-bundle-design.md)、[计划](../superpowers/plans/2026-10-25-backup-bundle.md)。机器摘要另见[evidence](evidence/2026-10-25-backup-bundle.json)。

## 交付与测试区分

新增生产`backup_bundle.py`和CLI `backup-create/backup-check`，复用原完整删除清单的同session导出。没有新增依赖、schema、Flutter或Node改动。创建只读数据库，使用同快照PG17 custom dump与删除清单，manifest最后发布；离线检查不读Settings、不建engine。

43项纯组件使用合成header/文件或受控本地工具，验证严格manifest、重复key、权限/符号链接、大小/hash/清单损坏、显式环境与脱敏、警告/超时/输出上限、进程组及失败清理。合成PGDMP数据故意不能恢复，只证明边界；返回`restore_verified:false/latest_deletions_verified:false`始终保留。11项真实SQL/CLI组合涵盖只读零写、当前schema要求、错误隔离级别、既有目标拒绝、外部文件保留及离线CLI禁止Settings/engine。

其中两项明确启用真实容器PostgreSQL17工具：一项含2凭据/3成员的完整备份恢复后全部表逐行一致；另一项在导出快照后、实际pg_dump前提交真实API删除，备份内清单仍空且恢复仍为原快照，最新权威清单为1条。恢复后应用最新清单清空文字/复盘输入/任务/结果，unknown连接继续占用；二次重放全表不变。这证明快照一致，也证明不能只靠包内清单恢复开放服务。

本机没有宿主pg_dump/pg_restore，测试显式配置临时私有wrapper，通过既有Compose容器执行17工具；生产代码没有嵌入Docker或测试替身。实际恢复目标均为专属随机测试库，断开连接后删除。

## 发现与修正

初始缺模块1项RED后实现。另两项失败清理先RED，覆盖写fsync失败与kill竞争。删除清单已link发布后父目录fsync失败曾遗留文件，1项RED后按发布inode撤回。

独立审查发现leader先退出时子进程可继续持管道，以及底层失败可能误删同路径替换文件，新增3项先失败后修正。复审发现上层`remember()`在成功写入后才lstat仍会误认外部替换；manifest/dump/清单三项均先RED。现各writer交回独占FD或link发布的device/inode，上层先记原身份再验证路径，清理只作用于原身份。最终独立只读终审未发现剩余确定问题，审查者另跑43项组件通过，未跑数据库测试。

## 最终证据

最终源码目标集：新增54项加原删除导出/CLI28项，共82通过（24.62秒）。全部测试使用本轮独立测试库，不使用开发库运行TRUNCATE。

最终API全量975通过（189.45秒），显式启用两项真实工具恢复测试，无skip。安装后CLI再对专属测试源执行真实backup-create，在无效Settings下backup-check通过；pg_restore至另一隔离库后21表逐行一致，源库全行不变。命令自身仍正确返回restore_verified:false，实际恢复证据由本次独立演练提供。Alembic check无新upgrade operations，未新增迁移。

Ruff检查、106份Python格式检查及38包离线锁检查通过。最终wheel源码与三份生产模块逐字节一致；29项runtime依赖的独立环境不含pytest。在仓库外运行安装后CLI，以无效数据库/环境配置仍通过合成包离线检查，确认未误初始化Settings；此项不证明合成dump可恢复。

## 保留的边界

开发库20业务表和迁移记录通过只读全行摘要比较；未备份真实开发账号数据。开工744个既有文件按SHA256检查保留，只修改本单元列明的7个原文件：cli.py、deletion_archive.py与HANDOFF/本地运行/技术设计/建设路线/验证计划；其余737个摘要未变，无丢失。专属源库已确认零连接后删除，随机恢复库及安装包恢复库均无残留；私有dump、脚本、runtime和日志已统一移除，报告不保留正文/密码/URL或私有备份。

没有自动调度、异地存储、实时删除日志、自动7/14天过期、生产切换或供应商调用。hash不认证来源/最新性，包内清单仅是备份快照；人工停服恢复仍需可信最新独立清单。原生、计费模型、物理麦克风、提交、推送和部署未执行，阶段5及完整产品均未标完成。
