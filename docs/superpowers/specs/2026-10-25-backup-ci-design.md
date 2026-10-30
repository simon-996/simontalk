# 真实备份恢复纳入CI

现有API工作流提供PostgreSQL17服务，但未传入两项真实恢复测试的工具路径，pg_tools夹具会skip。人工实测不能替代持续回归。本单元只补测试基础设施，不修改备份生产代码、依赖、schema、客户端或部署。

采用现有服务容器内工具。相比在runner安装客户端，能与服务版本保持一致；相比第二次启动数据库容器，复用现有服务即可。GitHub公开[service id上下文](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)与Docker官方[exec环境/交互输入](https://docs.docker.com/reference/cli/docker/container/exec/)支持此方式。

新增stdlib生成器scripts/prepare_test_postgres_tools.py，输入已运行容器的12–64位十六进制ID及新的绝对目录；创建0700目录和两个0700可执行入口。入口固定调用pg_dump或pg_restore，无shell；Docker绝对路径、容器ID和Docker配置HOME在准备时固定，连接PG*仅运行时转发环境变量名，密码不写入文件或argv。PGHOST/PGPORT固定为容器内部127.0.0.1:5432，stdin保留用于restore，stdout/stderr及退出码透传。生成器不创建/删除容器，不调用生产数据库，也不自动重建目录。

工作流在uv同步后生成入口，在pytest前设置SIMONTALK_REQUIRE_REAL_BACKUP_TESTS=1与两个绝对路径。pg_tools在强制模式缺失任何路径时fail；普通本地运行仍明确skip。配置完整但工具不存在/坏工具不回退成skip，实际测试应失败。运行全量测试时两项真实恢复必须执行。

验证包括缺工具先RED、生成器拒绝坏ID/相对或既有目标、受控Docker替身检查二进制stdin/stdout/退出码与环境不泄漏；再用实际PG17容器和专属测试库执行两项恢复及全量。工作流做语法/表达式检查；本机结果不称GitHub已通过，远端运行仍待提交/推送授权。
