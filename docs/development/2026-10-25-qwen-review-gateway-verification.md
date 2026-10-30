# 千问文本反馈候选验证

日期：2026-10-25（Asia/Shanghai）。连续完成浏览器竞态补验后，按[设计](../superpowers/specs/2026-10-25-qwen-review-gateway-design.md)及[计划](../superpowers/plans/2026-10-25-qwen-review-gateway.md)推进B5。实现`services/api/src/simontalk_api/qwen_review_gateway.py`，复用既有持久任务、ReviewGateway及生产worker；没有第二套任务或新页面。配置与失败语义见[契约](../architecture/2026-10-25-qwen-review-gateway.md)。

## 范围与实测

供应商HTTP全部为显式MockTransport；组合测试使用实际FastAPI路由、SQLAlchemy/PostgreSQL及生产worker。没有请求真实供应商、没有真实用户文字或密钥发送，不能据此认定qwen-flash已可用或语言质量达标。create_app和环境Settings均未改，默认仍Unavailable。

| 检查 | 实际证据 |
| --- | --- |
| 组件 | 最终102项；配置/指纹、请求去UUID和逻辑key、上下文资格、输入冻结、精确引用/类型/零项、usage未知与0、编码/重复key/长度/分块上限、错误脱敏/7秒/取消关闭/default关闭 |
| 实际worker组合 | 11项；默认blocked/0外调、claim已提交且外调不持行锁、建议/usage、合法空项、非法quote拒绝、未知不重复、429永久拒绝、外调中实际删除不恢复正文、配置变化调用前blocked，以及三种坏外层明确重试仍不再派发 |
| 目标总计 | 113 passed / 4.10秒，两个新增测试文件 |
| 后端全量 | 最终921 passed / 188.07秒；修复后的全量，不使用首轮907替代 |
| 静态与依赖 | Ruff通过，103 Python文件格式通过；uv离线锁检查38包，pyproject.toml/uv.lock相对开工未改 |
| wheel/runtime | wheel构建成功，候选源码逐字节一致且无.env；无pytest的独立Python3.13环境离线安装29个runtime依赖及wheel，HTTPX0.28.1，受控单次HTTP返回合法空项/未知usage；默认create_app仍Unavailable |

最初先观察模块缺失失败，再逐步实现；后续边界用例不全部宣称逐项RED。首轮全量907通过后独立只读审查发现1项P2：坏Chat外层原被当invalid_output，明确重试可能再派发。补13组件场景和3真实worker场景，先实际16 failed，再修复choices/index/finish类型及message结构为QwenReviewUnconfirmed；两条原invalid边界随正确语义迁移，最终102组件+11组合。独立复审组件102通过，无剩余确定问题；组合/全量由主执行者验证。

完整消息但finish非stop或工具/拒绝/推理、content建议不合格仍为invalid_output；缺/空/多choices、错误index/finish类型、缺message或错误role/content结构是unknown。未知非幂等调用即使明确重试仍只有一次attempt/HTTP，不用空建议掩盖失败。

wheel SHA-256：`f90b59656b0e86157922906a6c6e11758b6299e7d574d37661140d90ee8da6d5`。临时runtime从安装包site-packages导入，未借用源目录或开发pytest；检查只有MockTransport，实际供应商调用0。

## 数据、工作区与剩余条件

组合/全量使用本轮专属`simontalk_qwen_review_20261025_b57c1_test`，未使用共享开发/测试库。开发库20业务表及迁移记录全行摘要与浏览器单元基线一致；没有schema或依赖变化。本轮证据见[脱敏摘要](evidence/2026-10-25-qwen-review-gateway.json)，无请求正文/供应商异常正文或密钥。

Alembic check实际返回No new upgrade operations detected。专属库在确认零活跃连接后删除；临时runtime及本轮私有日志/脚本已移除。开工418个已有文件均保留；仅HANDOFF及技术/本地运行/路线/验证共5份原文档有意更新，原应用文件、依赖锁和其他既有文件摘要完全相同。六张浏览器补验截图已逐张查看；文档本地引用/围栏及Git空白检查随收尾核对。

实际权限/workspace/地域、允许预算、真实响应头/model回显/7秒适配、人工语言质量和供应商留存仍待验证。开工只检查配置是否存在（不输出值），相关Key/workspace/budget均未提供，沿用已暂缓安排；本候选没有自动启用入口。B2可信终止/失效与播放截断、正式媒体/结束保存页、B5真实反馈、B6及真机/大陆网络仍未完成。Flutter/Node没有改动或重跑；无原生构建、提交、推送或部署。
