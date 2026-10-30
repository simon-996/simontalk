# 千问文本反馈候选边界

日期：2026-10-25。[设计](../superpowers/specs/2026-10-25-qwen-review-gateway-design.md)；实现`services/api/src/simontalk_api/qwen_review_gateway.py`。标准create_app现支持[显式配置接入](2026-10-25-review-provider-config.md)，默认仍disabled。旧段落中的“未提供启用入口”是原候选单元历史范围，不能以类存在宣称完整真实反馈流程可用。

## 供应商契约

继续[真实worker组合验证](../development/2026-10-25-qwen-audio-worker-verification.md)补齐：实际ASR文字的隔离离线重放经真实API/SQL/生产worker调用一次3.8候选，空建议/650与5 Token落库、GET/重启不重调、账号隔离及删除通过；六类原组合场景现同时覆盖两个型号。仍不是实时通话业务范围或本轮浏览器UI验收，默认应用关闭。

后续2026-10-25[真实生成验证](../development/2026-10-25-qwen-review-live-verification.md)发现旧候选的字段/语义失败，现保留其JSON Object路径，新增显式qwen3.8-flash strict JSON Schema候选；完整六必填字段/枚举/禁止额外键，仍经全部本地校验。当前QwenReviewSettings.model只允许这两个型号，capability绑定各自实际选项，默认应用仍关闭。8次真实样本及最终两组人工抽查是新增证据；下文“仅qwen-flash/替身HTTP/真实仍缺”为原候选单元的历史范围，当前状态以本段及新验证为准。7秒/256KiB/2048Token、单次无重试和全部身份/引用门不变；不以schema保证语义。

依据官方[OpenAI兼容Chat](https://help.aliyun.com/zh/model-studio/compatibility-of-openai-with-dashscope)与[JSON输出](https://help.aliyun.com/zh/model-studio/qwen-structured-output)，限定北京workspace的`/compatible-mode/v1/chat/completions`、qwen-flash候选、非流式及非思考JSON Object。接口名称或JSON格式不能证明账号权限、允许预算、延迟或建议质量；须在真实接入前分别核验。

## 配置与输入

QwenReviewSettings不可变，workspace是1–63位小写DNS label，标签1–48位ASCII字母数字/点/横线/下划线，密钥1–4096可见ASCII并隐藏repr；model仅qwen-flash。capability的config_id为标签加SHA-256，绑定workspace、model、完整提示词、选项和review_generation_v1；更换非秘密配置改变身份，换密钥不改变。supports_idempotency固定false，不发送逻辑key作为上游幂等承诺。

请求只能是ReviewRequest、非空tuple targets、已支持策略；原范围UUID/修订、资格、依据、前文及文字在I/O前校验。最多8192 targets，请求512KiB；文本计入UTF-8预算且最终序列化大小再次受限，不截断。前文只有允许conversation_context时可发送，限定用户/助手角色。

上游数据仅整数target_id、原文字、资格、依据及前文角色/文字，不发送业务账号、练习、连接/话轮UUID或logical_request_key。响应按本次冻结输入在本地映射原UUID/修订；外调过程中原Python字典变化不改变映射。文本仍属于用户内容，真实发送需对应账号、隐私/预算条件齐备，本轮只有替身HTTP。

## 有界单次HTTP

固定URL，POST JSON，stream=false、enable_thinking=false、response_format=json_object、n=1、temperature=0、max_tokens=2048；不启用工具/搜索。每次独立HTTPX client/transport，trust_env=false、retries=0、follow_redirects=false。HTTP/读取/关闭共7秒，上层worker既有8秒继续约束整个生成，未改lease/事务。

只接200/application-json及identity，Content-Length若有必须合法、≤256KiB且实收匹配；按raw分块计数，超限立即停止。UTF-8严格解码，JSON拒重复key和NaN/Infinity。外层object/model须符合候选；只接一条index0、stop、assistant纯文本content，不接截断、工具、拒绝或推理正文。

缺失/空/多项choices、非法index/finish类型或message角色/content结构均是坏外层，保持outcome_unknown；结构完整但finish非stop、工具/拒绝/推理内容是已知invalid_output。

content只认含suggestions的对象、0–3项严格字段；整数target_id必须存在，quote必须为该原文非空精确子串，basis必须在允许集合，其他字段经原ReviewSuggestion校验。任一非法整体给ReviewGeneration(suggestions=None)，worker记录invalid_output而非虚构零项；合法[]才是no_suggestions。worker仍独立重建封存来源、核版本/精确引用与依据，保持删除/租约门。

实际合法usage映射prompt_tokens/completion_tokens；缺失保持None，显式0保留0，非法或total不一致整体视为未知。没有金额换算、账单对账或硬上限能力。

## 失败语义

本候选对明确HTTP400/401/403/404/413/422/429采用已知永久拒绝，不读错误正文，也不自动重试。5xx/重定向、网络/超时、非法/截断外层和编码/长度/大小失败使用固定QwenReviewUnconfirmed；原SDK异常context/cause不跨边界。外部CancelledError原样传播并关闭资源。

未知不是已知未受理，非幂等capability使worker保持failed/outcome_unknown；明确重试也不能重新派发未知调用。配置指纹变化时，已捕获claim在外调前blocked。默认工厂仍Unavailable，不能靠环境里有Key自动开启。

验证结果与边界见[本轮验证](../development/2026-10-25-qwen-review-gateway-verification.md)。真实供应商响应头、model回显、7秒时延适配、账号权限和人工语义抽查仍缺；未修改数据库schema或客户端。
