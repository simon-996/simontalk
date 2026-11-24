# 受主管约束的消息泵会话实施

目标：在不注册路由的前提下，以一个生命周期管理真实主管、消息泵与专属下游。

1. [x] 在 `services/api/tests/test_supervised_pump_session.py` 覆盖正常 stop、上下游失败、启动失败、取消、运行期身份失效、阻塞/忽略取消任务的有界与容量保留；用已有真实主管和消息泵及假 socket/身份复验。重复使用下游及迟到发送两个测试先失败。
2. [x] 运行目标测试确认入口缺失后，在 `services/api/src/simontalk_api/supervised_pump_session.py` 实现单读上下行及并发关闭，所有异常脱敏；测试发现 stop 与上游关闭竞争，已由已验证 stop 标记处理。
3. [x] 执行相关音频/主管测试、Ruff 和格式检查；记录真实数据库、公开路由与模型未验证的边界，更新 HANDOFF。
