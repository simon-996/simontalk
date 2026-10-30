# 千问候选信令与基础API流程验证

日期：2026-10-24。依据[设计](../superpowers/specs/2026-10-24-qwen-webrtc-signalling-design.md)和[计划](../superpowers/plans/2026-10-24-qwen-webrtc-signalling.md)，连续完成候选网关、实际API组合、运行打包和基础数据流程演练。实现及官方来源见[契约](../architecture/2026-10-24-qwen-webrtc-signalling.md)。

## 已交付

新增不可变服务端配置与QwenWebRtcSignallingGateway：固定北京workspace HTTPS地址、四字段配置绑定、原SDP单次POST、7秒HTTP截止、64KiB增量/UTF-8校验、无重定向/重试/环境代理、取消关闭与错误脱敏。每次使用独立HTTP客户端；上层现有8秒、数据库先claim、原offer防重和unknown核验不变。配置/输入拒绝在HTTP客户端创建前完成。

create_app、准入和客户端协议仍Unavailable；环境中存在API Key也不会自动开启。本轮没有实际模型、账号权限、设备语音、播放对齐或可信上游退出证据，不将候选模块/替身测试记为千问已接通。

HTTPX由已有dev提升runtime，仍0.28.1；锁中38个包版本逐项不变。未改schema、旧控制器、事务协议或Flutter。原集成工作区保留，HEAD仍04067ea，未提交/推送/部署。

## 验证结果

| 检查 | 实际结果 |
| --- | --- |
| 候选组件 | 79通过/约0.15秒；静默构造、精确配置/非法输入、URL/头/原字节、状态/编码/长度/格式、分块停止、超时/取消关闭、无敏感exception context及默认关闭 |
| API组合目标 | 111通过/5.55秒，含79组件+8新组合+24既有信令；实际ASGI handler与PostgreSQL，供应商HTTP为MockTransport |
| 后端全量 | **808通过/186.41秒**，新增79组件+8组合+1贯通共88项；先前799/807为中间验证 |
| 贯通演练 | 1通过/1.17秒，不直接修改数据库业务状态 |
| Ruff/格式 | 全库通过；100个Python文件格式符合 |
| 锁文件 | uv lock --check --offline通过；38包版本未变 |
| 打包 | wheel包含与源码逐字相同候选模块，HTTPX为runtime依赖，无.env文件 |
| 无测试工具运行环境 | 独立非editable安装，无pytest；HTTPX0.28.1、实际模块导入、受控交换及默认app关闭检查通过 |
| 独立只读审查 | 网关、API组合、贯通测试三次均无确定问题 |

新模块测试最初因模块不存在ImportError，属于功能缺失RED，不声称79条分别见过行为失败。贯通测试的fixture依赖漏导入与测试用户名含非法连字符分别导致setup/输入422，均按实际错误修正；未因此改生产行为。

## API组合证据

MockTransport请求中另开真实数据库事务取得连接FOR UPDATE，并观察negotiating/unknown/offer摘要，确认claim已提交且未持有该连接锁。成功后仍configuring/unknown；重复offer及重建应用后同offer409，上游合计一次。配置变化503且零claim/零核验任务；拒绝、重定向、非法/超限答案和超时分别502/504，均保持unknown、blocked/attempts=0及禁止重复交换。无敏感上游正文进入API错误。

## 基础流程贯通范围

实际API注册A并保存个人难度→准备/候选SDP→申报明确样本文字→end/manifest sealed/incomplete→默认反馈blocked→明确测试Gateway重试→生产worker及结果/原话定位→目标只读/unknown拒绝新重练→B账号隔离与独立准备→A删除/原key重放。删除后A正文/反馈/旧地址不可读，unknown仍占用、blocked0保留，B记录不受影响，供应商/反馈各仅一项替身调用。

文字是client_reported样本，反馈由已有固定测试Gateway产生；未生成播放/终止证明，没有直接SQL伪造ready/confirmed。这是跨模块工程验证，不是实际口语、建议质量、浏览器或完整B6验收。

## 数据与环境保留

各次执行都新建本轮专属*_test库，禁止使用开发库或共享simontalk_test；完成后删除。开发库20业务表及alembic_version全行摘要前后一致，未升级开发schema。API使用进程内ASGI TestClient，不启动对外监听服务；无真实供应商网络请求。

证据：[全量与开发库](evidence/2026-10-24-qwen-webrtc-signalling-database.json)、[API组合目标](evidence/2026-10-24-qwen-webrtc-signalling-target-database.json)、[流程演练](evidence/2026-10-24-qwen-webrtc-signalling-flow-database.json)、[无pytest运行环境](evidence/2026-10-24-qwen-webrtc-signalling-runtime.json)、[工作区保留](evidence/2026-10-24-qwen-webrtc-signalling-preservation.json)。Flutter/Node/Web未改未重跑，先前1236/58/Web49.5秒为历史证据。

实际浏览器工具本轮再次提示Work设置禁用。下一步按B2/B5核对实际账号/workspace/地域/权限、允许费用、可信终止及播放/截断，再接正式客户端协议和通话/结束操作；实际供应商响应头/格式与语音/网络仍需实测。已有暂缓输入安排保持，不自动付费调用或降低unknown/准入约束。

最终收口：8份相关文档/196本地引用、围栏/空白及Git diff检查通过；本轮16项临时日志/脚本/摘要和隔离wheel/runtime已清理。原666文件仍存在，304个客户端文件逐项不变；本轮仅修改六份已有文件（状态/信令文档、路线/验收、pyproject及lock），其余原工作保留。候选库残留查询为0。
