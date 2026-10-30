# 千问私有配置读取与测试预算

日期：2026-10-25（Asia/Shanghai）。用户明确要求写入所给Key后开始开发，随后确认首轮真实测试预算20元。真实Key/workspace已写后端Git忽略的.env，权限0600，不在本报告/测试/源码中保存值。[设计](../superpowers/specs/2026-10-25-qwen-private-config-design.md)、[计划](../superpowers/plans/2026-10-25-qwen-private-config.md)。

## 已接通的开发单元

新增独立`load_qwen_realtime_settings(env_file=...)`，将SIMONTALK_QWEN_私有配置转为既有QwenWebRtcSettings。API Key使用SecretStr，最终dataclass repr继续隐藏Key；型号、workspace、标签、Key限制复用既有校验。默认读当前目录.env，显式文件可指定，环境变量优先；失败抛稳定ValueError，不携带原输入/异常context。

新增13项缺模块断言先RED，随后配置/环境覆盖、缺失/非法值、脱敏错误、无网络与默认三Unavailable保护通过。新13加原信令/反馈组件共194项通过（0.34秒）；独立只读审查另跑13/0.11秒，无确定问题，未读取真实.env或调用数据库/网络。真实私有文件已离线构造参数并通过现有gateway配置检查，输出只有成功布尔值，0供应商请求。

本单元不改变create_app、PracticeAdmission、默认signalling/review网关，不因有Key自动启用真实模型或语音。没有前端密钥字段、API接口、依赖或schema变更。原[只读鉴权](evidence/2026-10-25-qwen-readonly-auth.json)为此前两次目录GET证据，本轮不重复计入。

最终API全量1004项通过（191.98秒），真实备份恢复明确启用、零skip；Alembic check无新upgrade operations。Ruff/110文件格式、38包离线锁检查通过；wheel包含最终loader，逐字节匹配源码，既无私有.env也无真实Key。未重跑Flutter/Node或原生构建，未提交/推送/部署。

## 费用估计与授权边界

截至本次核对，当前Plus候选北京地域音频输入80元/百万Token、音频输出300元/百万Token；普通音频输入每秒7 Token、输出每秒12.5 Token。多轮会将上下文内的历史重新计入输入，不能只按本轮新增时长估价。[官方价格](https://help.aliyun.com/zh/model-studio/model-pricing)、[Token换算与上下文规则](https://help.aliyun.com/zh/model-studio/realtime)。

工程估算：10轮、每轮用户/AI各说30秒，共10分钟；若历史音频均保留，按每轮累计历史的简化模型，音频输入约21000 Token、输出3750 Token，约2.805元。此估算不含系统提示/历史文本、重试、其他输入或异常未退出，未扣未知免费额度，不是账单或费用上界。首轮若含多组短会话/失败与插话测试，建议预留20元、预估5–15元；用户已确认20元授权上限。

20元尚未转化为供应商侧已证明的硬停费机制。本轮0推理请求、无新语音会话、无音频上传；预算确认不替代可信退出或费用核验。下一步先核验供应商控制/失效路径、实际退出和用量来源，再逐步接正式通话/结束页。Key/workspace基础鉴权已证实，不等于实际语音权限、质量、退出或完整B2/B5/B6通过。

开发21表全行摘要保持不变，源测试库及恢复库已清理；开工777个既有文件保留，仅.env.example与HANDOFF/本地运行/验证计划4份原文件有意更新，其余773个摘要未变。私有.env按本次用户明确授权更新，不进入Git或安装包；临时测试dump、工具、wheel和日志用后清理，摘要另见[机器证据](evidence/2026-10-25-qwen-private-config.json)。
