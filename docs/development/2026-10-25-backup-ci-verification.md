# 真实备份恢复CI接线验证

日期：2026-10-25，Asia/Shanghai。[设计](../superpowers/specs/2026-10-25-backup-ci-design.md)、[计划](../superpowers/plans/2026-10-25-backup-ci.md)、[机器摘要](evidence/2026-10-25-backup-ci.json)。修正现有工作流未配置工具、两项真实恢复会被skip的缺口；不改变生产备份格式、API业务逻辑或用户流程。

## 改动与边界

新增`prepare_test_postgres_tools.py`生成两个私有可执行入口；API工作流在依赖同步后，复用已有PG17服务ID，生成到runner.temp，pytest明确配置required及两个绝对路径。`pg_tools`夹具在required=1且缺任一路径时fail，普通本地无工具仍skip。配置完整但工具损坏不回退skip。

GitHub官方定义[服务容器ID及runner上下文](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)，Docker官方支持[exec -i与按名称转发环境](https://docs.docker.com/reference/cli/docker/container/exec/)。此处没有增加服务、数据库依赖、权限或外部账号；工具使用服务镜像内的客户端，与PG17服务一致。入口固定Docker绝对路径/容器ID/HOME，无shell；密码不写文件或argv，PG环境运行时传入，stdin/stdout/stderr及退出码透传。

生成器要求合法hex容器ID和新绝对目录；既有目录/文件/链接不覆盖。目录/入口0700，入口要求PGDATABASE以_test结尾。它是隔离测试辅助，不是通用生产恢复安全边界；本轮只访问专属测试数据库，开发库仅只读摘要。

## 实际验证

新增16项：required缺dump、缺restore、全缺均不得skip；普通模式仍skip；受控Docker替身验证两个工具的二进制流、非零退出、stderr、env名称及秘密不进argv/生成文件；非法ID、相对或既有目标拒绝，非测试PGDATABASE不启动工具。

初始观察3项失败、1项通过、12项因生成器尚缺而setup断言失败；实现后16项通过（0.20秒）。独立只读审查另跑16项/0.20秒通过，无确定问题，未连接数据库或修改文件。

实际用本轮生成器对既有本地PG17容器创建入口，在干净PG环境执行既有两项真实恢复：全表恢复与快照后删除/最新清单重放，两项通过（2.70秒），不是伪PGDMP替身。专属源库为`simontalk_backup_ci_20261025_a6d12_test`，恢复目标由测试独立创建并删除。

最终API全量991项通过（187.50秒），两项真实恢复明确启用、零skip；Alembic check无新upgrade operations。Ruff及108文件格式、38包离线锁检查通过。工作流YAML可解析；官方actionlint v1.7.7发布包经官方checksums验证后，本机检查工作流退出0、无诊断。没有全局安装校验器，发布包和工具用后清理。

没有提交/推送/触发GitHub，因此不把本机验证称为远端Checks已通过。生产包源码/依赖/schema、Flutter/Node均未变，未重建wheel或重跑无关客户端检查。前批API975/Flutter1401等保留历史含义；本轮数量只以本轮日志为准。自动备份调度、异地清单、保留期及B2/B5/B6仍未完成。

## 数据保留与清理

开发20业务表和迁移记录共21表全行摘要不变，专属源库零活跃连接后已删除，随机恢复库无残留。开工770个既有文件保留；仅工作流、原恢复测试夹具及HANDOFF/本地运行/验证计划共5个原文件有意更新，其余765个摘要不变。测试dump、生成入口、校验器与私有日志/脚本已统一清理，数量写入机器摘要；既有开发容器和卷保留。
