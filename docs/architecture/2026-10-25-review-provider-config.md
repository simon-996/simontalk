# 后端复盘供应商配置

标准create_app现可从明确配置构造复盘网关，替代测试脚本直接修改app.state。默认模式disabled；Key或workspace存在本身不启用网关，不影响语音准入/信令。设计与验证见[设计](../superpowers/specs/2026-10-25-review-provider-config-design.md)、[验证报告](../development/2026-10-25-review-provider-config-verification.md)。

| 配置 | 默认 | 行为 |
| --- | --- | --- |
| SIMONTALK_REVIEW_PROVIDER | disabled | 仅disabled/qwen，未知值启动失败 |
| SIMONTALK_QWEN_ENV_FILE | .env | 私有参数文件，相对路径以启动工作目录为准；同名进程环境变量优先。Python Settings可传None，仅用进程环境 |
| SIMONTALK_QWEN_API_KEY | 无 | 仅私有loader读取，通用Settings/API/客户端不保留Key |
| SIMONTALK_QWEN_WORKSPACE_ID | 无 | 固定北京workspace地址中的合法DNS标签 |
| SIMONTALK_QWEN_REVIEW_MODEL | qwen3.8-flash | 本配置入口仅接受该型号；旧qwen-flash仍可作候选类构造，但不能由此开关启用 |
| SIMONTALK_QWEN_REVIEW_CONFIG_ID | qwen-review-v1 | 1–48位已有标签约束；与实际模型/提示/选项共同派生capability |

从services/api运行，在已有私有配置上显式设置SIMONTALK_REVIEW_PROVIDER=qwen，再使用原Uvicorn启动命令即可。文件位置不同则同时设置SIMONTALK_QWEN_ENV_FILE的绝对路径。禁用使用disabled并重启。不要覆盖已有.env或把Key放进启动命令、前端、公开环境示例或Git。

## 启动及运行边界

disabled返回UnavailableReviewGateway，不调用私有loader或构造HTTP客户端；未提供Key仍可启动。qwen模式在数据库引擎、生命周期runner创建前读取并验证私有参数，无效/缺失时用稳定错误停止启动，不静默换模型或降级。SecretStr/repr与错误脱敏沿用既有私有读取规则，无原异常context/cause。

网关只在启动装配一次，修改文件不会热切换已有实例，需重启。构造应用不发模型请求；显式启用后的既有runner会处理合法已排队任务，所以开关不是仅展示模型可用性的标志。已blocked任务仍需原有明确操作；配置改变后原claim在外调前blocked。禁用停止新领取，保留任务真实状态，不能撤回已经发出的HTTP或把unknown费用记为0。

复用既有本人来源/版本/原话校验、单次有界HTTP、非幂等未知不重派及删除晚回包保护，没有新公开端点、schema或任务重试规则。后台复盘配置与语音供应商准入分开；真实语音退出/失效和播放截断仍未满足，普通语音入口仍503。

本轮真实验证只在独立测试库显式启用此配置，实际日常私有.env未改，默认启动仍disabled。实际语义抽查及ASR文字离线重放不等于实时通话→反馈的产品验收，也不构成费用硬上限。
