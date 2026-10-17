# Guarded Signalling Implementation Plan

> 使用superpowers:executing-plans在现有干净功能分支执行，保持本地、不推送。沿既有授权继续，不重复审批。完成后按requesting-code-review独立只读复核。

**Goal:** 持久单次上游交换意图、安全信令边界和可取消的客户端HTTP signaller。

**Architecture:** signalling.py区分短数据库事务与异步外部交换；网关策略默认拒绝，无生产测试替身。Offer读取中间件有界接收；客户端独立ApiClient分支绑定原账号身份。

**Tech Stack:** FastAPI/ASGI、SQLAlchemy/PostgreSQL17、Alembic、asyncio、Dart/http/Flutter tests。

## Task 1: 后端持久单次交换

文件：新增`services/api/src/simontalk_api/signalling.py`、`signalling_routes.py`、`tests/test_signalling.py`；修改models/main并添加Alembic迁移，无新增依赖。

- [x] 先测默认拒绝、严格身份/输入、重复/并发只调用一次，运行`uv run pytest -q tests/test_signalling.py`观察缺少路由失败。
- [x] 添加摘要/开始与结束时间、一致性和终止证据约束；网关只提供本地check_configuration与异步exchange_offer，默认Unavailable。
- [x] prepare事务按既有锁顺序提交negotiating/unknown后才交换，8秒deadline；finish事务重新检查并只允许原有效尝试进入configuring。
- [x] 先测失败/撤销/配置变化/扫描后的晚到答案、摘要不含原SDP、数据库锁在外部调用期间已释放，再实现对应分支，失败保持unknown且不回not_started。

## Task 2: 请求边界

文件：新增`offer_body_limit.py`和`tests/test_offer_body_limit.py`，在main中于CORS内层注册。

- [x] 先测缺失/伪造Content-Length、分块超限、正常重放、断开与慢读取；实现96KiB/5秒总边界，不让超限体进入JSON解析。
- [x] 错误保留request_id/no-store/CORS且不回显原内容；SDP最多64KiB且只允许有限基础格式，不做供应商语义解析。

## Task 3: 客户端单次signaller

文件：修改`apps/client/lib/core/api_client.dart`，新增`features/realtime/api_realtime_signaller.dart`和对应测试。

- [x] 先测派生客户端跟随原账号身份、CSRF/凭证异步边界、取消不关共享客户端。
- [x] ApiClient.forkForAccount接收独立http.Client，保留API配置/TokenStore并动态读取源身份，沿原请求检查身份。
- [x] 先测单次、响应身份/体积、失败不重试、12秒总等待与晚到取消；实现RealtimeSignaller，无自动媒体或页面入口。
- [x] 独立复核重现响应头后close不足以取消body，先加4项失败测试，再以每请求AbortableRequest中止信号修复并复核。

## Task 4: 验证与交接

- [x] 后端全量/Ruff/Alembic；Flutter全量/分析/格式、Node、Web release和字体校验；独立只读审查并修复重要问题。
- [x] 开发库添加性迁移、重启本轮API，验证默认鉴权/关闭且不注入练习或调用供应商。
- [x] 更新API/技术/开发契约、验证报告与HANDOFF，本地提交，保留真实供应商和硬件暂缓边界。
