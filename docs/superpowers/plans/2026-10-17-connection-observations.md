# Connection Observations Implementation Plan

> 使用executing-plans执行现有功能分支；按持续授权直接实施，完成后requesting-code-review独立只读审查。不推送/部署，不启用模型或原生构建。

**Goal:** 将受限客户端媒体事实持久化并接入现有媒体控制器，保持业务和终止证据独立。

**Architecture:** 新观测子表/短事务追加及只读分页；独立有界journal串行提交，控制器只产生本地事实。现有body限制器扩展到观测路径。

**Tech Stack:** FastAPI/Pydantic、SQLAlchemy/PostgreSQL17/Alembic；Dart/http/Flutter/Riverpod，无新增依赖。

## Task 1: 后端受限追加与查询

- [x] 新增`services/api/tests/test_connection_observations.py`，先测缺少路由失败、持久重放、权限/代次、冲突原子性与状态不变。
- [x] 新增`connection_observations.py`、`observation_routes.py`，修改models/main并加迁移；锁后核对原连接身份，提交枚举事实，无状态转移；GET单查询快照分页。
- [x] 测并发、历史/unknown、256上限、DB外键/级联、锁后撤销和严格输入；实现边界，完整重放不占新额度。
- [x] 扩展连接请求body接收保护到observations的8KiB/5秒，保持offer原96KiB边界、CORS/no-store及慢响应回归。

## Task 2: 有界客户端journal

- [x] 新增`apps/client/test/features/realtime/connection_observation_journal_test.dart`先测单次批次、暂停/原事件重试、响应身份及独立HTTP所有权，运行观察缺少实现失败。
- [x] 新增`connection_observation_journal.dart`：受限事件/原因、64队列/16批次、稳定ID/序号、串行确认；每批独立ApiClient及8秒总截止，finish/abort/显式retry。
- [x] 补队列满/关闭保留、账号切换、取消/超时/迟到、未知错误脱敏测试；不自动重放、不写浏览器存储。

## Task 3: 媒体接入与交接

- [x] 在PracticeMediaController/Provider接入可选journal工厂，生成受保护本地事实；释放先于上报，默认503不创建journal，测试明确注入替身。
- [x] 组合测试验证真实HTTP journal、媒体停止不受观测失败影响、同账号/连接/代次及无终止声明。
- [x] 后端全量/Ruff/两库Alembic，Flutter全量/分析/格式、Node、Web/字体、独立审查及确定问题修复。
- [x] 开发库添加性迁移、重启本地API验证边界，不注入开发练习；更新契约/验证/HANDOFF并本地提交。

完成证据见[2026-10-18验证记录](../../development/2026-10-18-connection-observations-verification.md)。
