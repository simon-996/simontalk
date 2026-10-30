# 千问严格结构复盘候选实施计划

> 当前会话按executing-plans执行；用户已有连续开发授权，不增加逐步审批或提交。

**Goal:** 在保留严格拒绝边界的前提下，验证真实可用的复盘结构与语义。

**Architecture:** 既有QwenReviewGateway按显式型号选择JSON Object或strict JSON Schema。配置签名绑定实际选项；默认应用不启用。

**Tech Stack:** Python3.13、现有HTTPX/pytest，无新增依赖。

- [x] 原提示两次真实失败；补合法JSON示例后两轮语义仍失败，保留全部证据。
- [x] 在test_qwen_review_gateway.py新增新候选结构/映射、拒绝错误键、配置绑定测试；先运行观察新型号不被支持的失败。
- [x] 修改qwen_review_gateway.py：允许两个固定型号，用实际options构建输入和capability；新型号携带六必填字段、枚举及additionalProperties:false的schema。
- [x] 运行配置/信令/复盘目标测试，真实原样本及独立样本各请求一次；缺用量不记零，失败不自动重试。
- [x] 静态/格式/离线锁检查；只读复核代码与证据，更新HANDOFF及验收文档；保留既有文件并清理临时探针。
