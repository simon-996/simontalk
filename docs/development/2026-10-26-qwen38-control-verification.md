# 新版千问实时控制实测

**2026-11-11勘误：** 当时 `websockets==15.0.1` 默认连接器未显式禁用重定向；其默认会跟随重定向并复用请求头。本地假凭据复现及修复见[安全验证](2026-11-11-qwen-websocket-gateway-verification.md)。当次证据未记录完整握手链，无法判断是否实际发生重定向或凭据泄露；下文原时点的“无重定向”表述不应视为已证明。

日期：2026-10-26。用户明确恢复已配置千问的针对性实测，沿用首轮累计20元上限。本轮2次独立连接、每次仅1次短响应，无自动重试；型号 `qwen3.8-omni-flash-realtime`。没有麦克风采集、音频上传、设备播放或音频文件保存。

| 场景 | 实际结果 |
| --- | --- |
| 手动模式配置 | 两次HTTP101、session.created/updated；均确认最大输出64 Token及嵌套PCM配置 |
| 短语音生成 | 固定英文输入；两次 completed，分别收到46,080/49,920字节PCM，仅内存计数 |
| 删除本次真实AI项 | 发出 `conversation.item.delete` 后约86.7毫秒收到 `conversation.item.deleted`，item精确匹配 |
| 结束事件 | `session.finish` 返回 `invalid_request_error/invalid_value`，param为type，未收到 finished |
| 部分音频截断 | 另一连接在生成完成后对真实AI项发送一次 `conversation.item.truncate`，content_index=0、audio_end_ms=200；5秒内无确认或error。不能由此推断永不支持，也不能当作成功 |
| 关闭 | 两次均收到双方1000帧，本地close约5.003秒返回；不证明资源释放或最终结算 |

原始脱敏事件见[删除/结束](evidence/2026-10-26-qwen38-delete-finish.json)及[截断](evidence/2026-10-26-qwen38-truncate.json)。会话和AI项仅保留SHA256；不保存Key、完整会话配置指令或音频delta。

## 用量与费用

两次均返回完整Token细分：输入文本704/704，输出文本4/4、音频12/13，总量720/721。按[该型号北京价格](https://help.aliyun.com/zh/model-studio/qwen3-8-omni-flash-realtime)，文本输入1.5、文本输出4.5、音频输出12元/百万Token；语音及对应文本均计费。本轮已返回用量标价估算 **0.002448元**。没有核对结算账单或免费额度，不能宣称实际扣费为该数；此前取消缺用量仍未知，累计20元是授权上限，并非供应商硬停费配置。

## 协议依据与接入影响

[官方总览](https://help.aliyun.com/zh/model-studio/realtime)支持该型号北京workspace地址、文本输入、手动模式，并说明单会话最长120分钟后主动关闭。这是候选失效依据，但尚未核对丢失创建回包时的起算点、迟到创建和计费语义，不能直接作为当前 unknown 自动释放条件。

本轮首次得到该型号对真实项的删除确认，较此前仅SDK发送封装有实质进展。整项删除不能代替精确已播前缀保留；部分截断及结束确认仍未获得，不将其混同为自然插话或可信终止验收。[客户端](https://help.aliyun.com/zh/model-studio/client-events)与[服务端事件表](https://help.aliyun.com/zh/model-studio/server-events)当前仍未列出对应 finish/truncate 确认契约。

探针使用私有配置loader和临时 `websockets==15.0.1`，TLS验证、无代理/重定向/重试；每连接总截止40秒、握手7秒、控制确认5秒、接收128KiB/400事件/960,000音频字节上限、本地关闭5秒。没有改仓库依赖、生产型号允许列表或媒体准入，没有发送供应商询问稿。正式B2/B6仍未验收。
