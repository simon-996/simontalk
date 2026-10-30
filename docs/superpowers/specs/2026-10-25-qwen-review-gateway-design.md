# 千问文本反馈候选适配器

日期：2026-10-25。依据已有B5简单反馈、持久任务/引用门及用户连续开发授权。本单元仅完成可接入的服务端候选边界，不改变默认Unavailable，不调用真实模型、不增加页面占位或产品取舍。

## 选择与范围

复用现有ReviewGateway/ReviewRequest/ReviewGeneration/ReviewUsage及生产worker；不增加第二套任务、数据库或反馈API。直接使用已有runtime HTTPX完成一次非流式Chat Completions。供应商SDK会增加依赖及隐含重试面，通用任意端点会扩大配置边界，本轮限定北京workspace地址和公开资料支持非思考JSON模式的qwen-flash候选；这不是账号已选型号或效果验收。

官方来源：[兼容Chat接口](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)、[结构化输出](https://help.aliyun.com/zh/model-studio/qwen-structured-output)。使用JSON Object模式并本地校验，不把模型声称符合格式当可靠性证据；没有二次模型修复或自动切换。

## 输入与身份

不可变QwenReviewSettings持workspace_id、model、config_id标签和repr隐藏的api_key。workspace是合法DNS label，model仅qwen-flash，标签最多48位ASCII标识，密钥仅可见ASCII。ReviewCapability.supports_idempotency固定false；config_id由标签及非秘密配置、完整提示词、选项和策略的SHA-256派生，避免同标签换workspace或提示词后继续旧任务。轮换密钥不改变同一路线身份。

只接review_generation_v1和worker给出的非空、有界targets。每个target必须带有效原连接/话轮UUID、正修订、文本、eligible/uncertain、允许依据及安全前文；不接受excluded。完整请求上限512KiB，不截断，不超限外调。

上游只收到按本次输入排序的整数target_id、文字、资格、允许依据与安全前文的角色/文字。原连接/话轮UUID、账号、练习ID、逻辑请求key不外发；返回时由服务端按target_id映射原范围与修订。提示词要求把练习文字当数据、给0–3项少量建议、区分纠错/润色/扩展、不编发音分数、解释使用中文、建议使用英语；语言效果仍需真实模型人工抽查。

## 一次HTTP与结果

固定POST https://{workspace}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions。stream=false、enable_thinking=false、response_format=json_object、n=1、temperature=0、max_tokens=2048；没有工具、搜索或模型自选。每次独立client，trust_env=false、redirect=false、transport retries=0。HTTP/读取/关闭共7秒，上层worker既有8秒保留；外部取消传播并关闭资源。

只接200/application-json/identity，按原始字节增量读取，最多256KiB；合法Content-Length若存在须精确相符。UTF-8、JSON拒重复key/非有限数。外层须有效Chat响应；只认单一assistant、stop完成、无工具/拒绝/推理正文的content。模型字段须匹配候选名称，真实供应商返回差异须在后续实测时明确解决，不能静默降级。

content须是仅含suggestions的JSON对象、0–3项严格字段；target_id必须整数且存在，basis须在该目标允许集合，quote须为原文本非空精确子串。映射后用已有ReviewSuggestion类型检查，再由worker独立重建来源、核原话/依据和版本后原子保存。格式/内容不合格返回suggestions=None使worker记录invalid_output；不编空建议成功，不做付费修复。合法空数组才是no_suggestions。

usage只有实际合法prompt_tokens/completion_tokens时进入ReviewUsage；缺失保持None，非法或不一致usage整体弃用为未知，不填零。token数不等于费用结算。

## 异常和默认关闭

明确HTTP400/401/403/404/413/422/429是本候选的已知永久拒绝；不自动重试。5xx、重定向、传输/截止、坏外层、截断或编码/大小错误保持结果不明，以固定QwenReviewUnconfirmed跨边界，不泄漏上游正文/SDK异常上下文。因无已验证幂等，worker沿既有规则failed/outcome_unknown且不再调。已知输入失败在建client前安全拒绝。

不修改create_app、Settings环境加载、数据库schema或客户端。真实启用仍需账号/workspace/地域权限、允许预算、数据发送与语言质量验证；本轮只通过MockTransport和实际API/SQL/worker证明工程组合。

## 验证

先观察缺少候选模块的失败，再验请求范围/脱敏、精确映射、usage、零项/非法输出、长度/编码/状态、分块/取消/7秒有界、静默构造和默认关闭。独立库验证真实任务创建/claim/完成、精确引用、非法输出、unknown不重复与删除后晚结果不回写；开发库全行保留。全量API、Ruff/格式、wheel与无pytest环境导入验证后更新交接。无需重跑未变化的Flutter/Node。
