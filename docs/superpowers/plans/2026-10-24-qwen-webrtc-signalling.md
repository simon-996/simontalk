# 千问WebRTC候选信令适配执行计划

> 按superpowers:executing-plans/TDD逐任务执行。用户已授权按路线持续开发，不逐单元等待；沿用当前集成工作区，禁止提交/推送/部署/真实模型调用。

**Goal:** 交付可接现有SignallingGateway的一次性有界SDP适配，并保留默认关闭与unknown规则。

**Architecture:** 新模块services/api/src/simontalk_api/qwen_webrtc_signalling.py持有不可变服务端配置和独立异步HTTP边界；不改signalling.py事务claim/完成协议和main.py默认工厂。

**Tech Stack:** Python3.13、既有HTTPX0.28.1、pytest、PostgreSQL17；完整设计见对应spec。

## 1 官方核对和范围

- [x] 核对官方SDP、客户端/服务端事件和结束示例；明确可信退出/截断未通过，不启用任何网关。
- [x] 保存原工作区666文件摘要，核对HEAD04067ea/feat/account-foundation、无CodeGraph、无已附worktree。

## 2 测试先行与网关

文件：新增上述模块和services/api/tests/test_qwen_webrtc_signalling.py；只调整services/api/pyproject.toml与uv.lock中HTTPX依赖归属。

- [x] 先写测试：`QwenWebRtcSettings(workspace_id="workspace-1", model="qwen3.5-omni-flash-realtime", config_id="candidate-v1", api_key="test-secret")`构造静默，`gateway.check_configuration({...})`精确匹配；非法workspace/模型/key/config拒绝，网络factory零调用。
- [x] RED观察模块尚缺，再实现dataclass及check_configuration；输入无效直接422，配置不一致503；repr不得含key。
- [x] 用HTTPX MockTransport验证POST固定北京workspace地址、仅model查询、Bearer/SDP头、原始字节；成功只返回校验后的SDP。
- [x] 参数化非200/重定向、非SDP/压缩、格式错误/超限长度、UTF8/NUL/无前缀；分块超过上限立即拒绝并关闭，不读取错误正文。
- [x] 用受控AsyncByteStream验证超时/外部取消的请求释放、零重试；异常str/repr/traceback无原始密钥/SDP/上游异常，原Exception context不跨边界。
- [x] 运行`.venv/bin/pytest -q tests/test_qwen_webrtc_signalling.py`确认目标通过；修改依赖归属后`uv lock --offline`，比较所有package/version逐项不变。

## 3 集成验证与审查

新增实际API组合测试：services/api/tests/test_qwen_webrtc_signalling_integration.py；wheel与无pytest运行环境独立检查，仅上游传输为MockTransport。

- [x] 独立新建*_test库，只在该库运行目标signalling/默认准入及完整pytest；禁止使用simontalk或共享simontalk_test。不改schema，不启动对外监听API/供应商连接。
- [x] Ruff/format、默认create_app工厂、无真实客户端连接、开发库保留与所有原工作文件保留；独立只读审查，确定问题先RED修正。
- [x] 更新HANDOFF、B2矩阵及验证报告，清理独立库/临时摘要日志，继续下一项可独立工作。Flutter未改则保留先前1236/Node58/Web证据不冒充重跑。

## 4 基础数据流程贯通演练

- [x] 新增services/api/tests/test_qwen_practice_flow.py，复用实际注册/偏好/准备、候选SDP、客户端申报文字、end/manifest封存、默认blocked反馈→明确测试gateway重试→实际worker/结果/原话定位、重练unknown拒绝、A/B历史隔离、删除及原key凭据/unknown保留。除供应商/文字/反馈样本替身外，不直接改数据库业务状态。
- [x] 在另一个独立*_test库单独执行，记录开发库全行不变与临时库清理。此为API工程衔接演练，不是实际语音、浏览器或完整B6验收；不因测试数据补造已播放/已终止证明。
