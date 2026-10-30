# 千问实时模型首次真实连接、语音生成与取消实测

日期：2026-10-25（Asia/Shanghai）。用户已授权使用私有配置开始开发，并明确首轮真实语音测试预算20元。本轮是受控技术实验，使用既有配置中的北京 `qwen3.5-omni-plus-realtime`；没有改变产品默认协议、准入或网关。

## 实际结果

共6次独立WebSocket连接、2次明确的模型响应请求，均无重连或自动重试。全部收到HTTP101、`session.created`、`session.updated`及双方1000关闭帧。输入只有固定英文测试文本，没有采集或上传麦克风音频。收到的PCM仅在内存计数，没有播放或保存音频文件。[脱敏逐次证据](evidence/2026-10-25-qwen-realtime-live-probe.json)。

| 场景 | 结果 | 证据边界 |
| --- | --- | --- |
| 首两次配置检查 | 收到配置确认，但探针本地校验拒绝；均0次推理 | 探针要求显式回显`turn_detection:null`，实际服务端省略设为null的字段；不是供应商鉴权或更新失败 |
| 第三次配置检查 | `session.updated`回显`modalities:[text,audio]`与`max_tokens:64`，约0.293秒完成 | 对请求中设为null的字段允许省略，依据官方更新成功语义；不声称收到了显式null回显，也没有用音频验证VAD |
| 一次短语音生成 | 返回“Hello, ready to practise.”；首音频包距连接开始0.995秒，`completed`在1.926秒到达；收到84,480字节PCM | 首包时间是本机此连接的网络观测，不是首个声音播放时间或大陆设备延迟；不证明语音输入/识别/完整对话 |
| 单独`session.finish` | 更新确认后发送，收到`error/invalid_value`；未收到`session.finished` | 此次请求不能作为可用终止路径；不能据此推断其他模型、协议或后续供应商版本 |
| 首个音频包后取消 | 在1.006秒发送一次`response.cancel`，1.087秒收到`response.done/status:cancelled`；共收到30,720字节PCM | 取消后1.044秒还有一个音频delta；没有播放器、精确已播前缀或上下文截断确认。文本已先行生成较长片段，不能把全文当作已听内容 |
| 关闭观测 | 全部收到双方1000帧，但`close()`均约12.002秒才返回；新增时间观测中远端关闭帧约39–48毫秒到达，本机连接在12秒关闭超时附近才丢失 | 明确区分关闭帧、TCP/TLS清理、上游资源释放与费用结算。没有远端状态查询，不能用本机CLOSED释放产品unknown占用 |

## 用量与费用

完成的短回复返回实际`usage`：输入489个文本Token，输出30个Token（文本8、音频22），合计519。按[官方北京价格](https://help.aliyun.com/zh/model-studio/model-pricing)，该型号输入文本10元/百万Token、输出音频300元/百万Token；同时输出语音时对应文本不计费。因此这一条已返回用量的响应标价估算为：

`489 × 10 / 1,000,000 + 22 × 300 / 1,000,000 = 0.01149元`。

取消响应的`usage`缺失，保留null，不能记成0；四次未请求响应的连接也没有费用回报，不能据此宣称账单为0。本轮没有登录账单控制台或获取结算账单，因此总扣费和剩余额度均未核实，不以这一个响应的估算冒充本轮总费用。20元是用户授权上限，本地超时和`max_tokens`不是供应商硬停费证明；官方还说明`max_tokens`控制响应截断，并不影响模型生成过程。

## 实验实现与核验

- 通过现有`load_qwen_realtime_settings()`显式读取Git忽略的后端私有`.env`；Key只用于固定北京workspace域名的TLS Authorization，不输出到命令参数、日志、报告或前端。会话ID仅保存SHA256。
- 使用临时Python探针与`uv --locked --with websockets==15.0.1`，固定TLS验证、禁用代理/重定向/压缩/自动重试；单连接15秒握手、配置后25秒接收总截止、12秒关闭截止、单消息128KiB、400事件、接收音频480,000字节上限。两次响应各自配置并回显`max_tokens=64`；每条只请求一次响应。
- 第一、二次探针的本地检查失败完整保留；诊断后仅对请求设为null的字段接受服务端省略，并新增最大Token回显。没有把失败记录删除后只展示成功。
- 对6条证据重新核验HTTP101、双方1000帧及2次响应计数；核验完成用量519、finish错误与取消缺用量。JSON解析、相对链接、私有Key未进入新文件、原工作区文件保留均另作本地检查。
- 没有改应用源码、schema、仓库依赖或锁文件，没有连接业务数据库；不重跑或重标此前API1004、Flutter1401、Node58等历史结果。没有物理设备、WebRTC、自然语音输入、提交、推送、原生构建或部署。

## 对接入的影响

真实模型调用权限及文本输入到语音输出已有本轮证据；此前只有模型目录可读，现可据此更新状态。响应取消有实测，`session.finish`不能按其他模型事件补造；取消缺用量必须保留未知。关闭帧可作为这一实验的协议事实，但没有覆盖Answer丢失、客户端消失、业务后端崩溃后的远端终态与回收上界。

下一步集中补供应商可信退出/失效依据及播放截断，比较后端持有上游连接的路径与现有WebRTC候选。未选定替代产品，没有把WebSocket实验当作WebRTC验收。正式通话/结束页、B5真实文本反馈人工抽查及B6全流程仍待完成，默认三Unavailable及unknown占用语义保留。

官方依据：[实时模型总览](https://help.aliyun.com/zh/model-studio/realtime)、[客户端事件](https://help.aliyun.com/zh/model-studio/client-events)、[服务端事件](https://help.aliyun.com/zh/model-studio/server-events)、[WebSocket协议差异](https://help.aliyun.com/zh/model-studio/realtime-websocket-overview)、[WebSocket客户端库15.0.1](https://websockets.readthedocs.io/en/15.0.1/reference/asyncio/client.html)。总览的finish描述与专用事件表差异，以本次型号实际返回保留限制，不外推。
