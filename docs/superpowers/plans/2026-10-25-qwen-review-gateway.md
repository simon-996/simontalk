# 千问文本反馈候选适配器实施计划

> 执行时使用superpowers:executing-plans及test-driven-development。用户已有连续开发授权，常规选择按既有B5契约执行；不提交、推送、部署或开启真实调用。

**Goal:** 完成默认关闭、可与生产复盘worker组合的千问文本候选适配器。

**Architecture:** 一个独立HTTP边界，复用既有ReviewGateway与原话校验。测试用MockTransport替代供应商，实际数据库验证任务和来源规则。设计见[规格](../specs/2026-10-25-qwen-review-gateway-design.md)。

**Tech Stack:** Python3.13、HTTPX0.28.1、现有FastAPI/SQLAlchemy/pytest；不增加依赖。

## Task 1 配置、请求与成功结果

文件：新增`services/api/src/simontalk_api/qwen_review_gateway.py`和`services/api/tests/test_qwen_review_gateway.py`。

- [x] 先写模块存在、静默构造、严格配置和完整请求映射测试，运行`uv run --locked --no-sync pytest -q tests/test_qwen_review_gateway.py`观察缺少模块失败。
- [x] 实现QwenReviewSettings、不可幂等capability指纹、固定北京URL、去除业务身份的targets及提示词。核心断言：`assert gateway.capability.supports_idempotency is False`；`assert request.url.host == "test-workspace.cn-beijing.maas.aliyuncs.com"`；`assert "source_connection_id" not in request.content.decode()`。
- [x] 实现严格外层/JSON建议映射，合法引用返回`ReviewGeneration`，不合格content返回`suggestions=None`，真实零项返回`[]`。以来源UUID/修订的映射和usage未知/0区别验收。

## Task 2 HTTP边界与未知结果

沿用同一生产文件和组件测试文件。

- [x] 先写超时/取消、SDK敏感异常、非成功状态、编码/Content-Length/分块超限、重复key及非有限数测试，观察未实现行为失败。
- [x] 实现7秒总HTTP截止、独立client/无重试/环境代理/重定向、256KiB raw响应上限、关闭及异常脱敏。明确拒绝用ReviewGatewayError，其余用固定QwenReviewUnconfirmed，外部CancelledError原样传播。
- [x] 运行组件目标并检查断言：一次generate只发一次HTTP；超限不继续读；异常`__context__ is None`且错误字符串无原话/密钥；默认create_app.review_gateway仍Unavailable。

## Task 3 实际worker组合、回归与打包

文件：新增`services/api/tests/test_qwen_review_gateway_integration.py`；契约和验证分别写入docs/architecture和docs/development。

- [x] 独立*_test库先写真实生产worker组合：0–3项引用成功、有效空项、非法引用拒绝、传输未知不重试、删除发生在生成阶段后结果丢弃；默认API创建仍blocked/0调用。
- [x] 运行目标、全量API、`ruff check .`和`ruff format --check .`；未改schema只确认alembic check，无迁移。
- [x] wheel包含模块；独立无pytest runtime离线安装/导入及MockTransport受控交换通过。原锁文件与38包版本保持，不产生真实供应商请求。
- [x] 记录开发库全行摘要、原文件保留与临时资源清理；更新HANDOFF、B5验收矩阵和本地入口。不把候选测试当真实反馈/语义质量或完整基础版本。


执行记录：完成102组件+11实际worker组合，目标113/4.10秒；最终API921/188.07秒、Ruff/103格式/38包锁/metadata/wheel/runtime通过。先缺模块失败；后续边界并非逐例RED，初审坏外层问题另以16失败用例复现，修补后独立复审102通过。详见[验证](../../development/2026-10-25-qwen-review-gateway-verification.md)。无真实供应商/迁移/依赖/客户端变更，未提交/推送/部署。
