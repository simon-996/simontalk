# 握手到持久声明实施

目标：组合既有严格握手和持久声明，保护取消或超时后仍在运行的数据库事务。

1. [x] `services/api/tests/test_authenticated_websocket_claim.py` 先写 PostgreSQL 测试，覆盖真实握手与声明、非法预检/账号与重放，以及线程取消/超时后提交时保守 unknown、无上游连接；补真实行锁、提交后取消、容量保留及主管组合。
2. [x] `services/api/src/simontalk_api/authenticated_websocket_claim.py` 实现固定错误、有界任务和迟到声明补记；入口返回身份和声明，取消等待不取消数据库线程或触发供应商。
3. [x] 在隔离 PostgreSQL 运行新增测试和已有声明/身份/主管目标，执行 Ruff/格式并更新交接，关闭并删除临时容器。
