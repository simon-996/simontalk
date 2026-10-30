# 千问私有配置实施计划

按既有连续开发授权执行brainstorming/TDD/verification流程，不提交或推送。预算已确认为20元，本单元零推理调用。

- [x] 新tests/test_qwen_config.py，动态导入缺失模块先RED；临时私有.env测试构造既有参数、环境覆盖、缺字段/非法值、稳定脱敏错误及无网络。
- [x] 新src/simontalk_api/qwen_config.py，仅独立私有BaseSettings和load_qwen_realtime_settings；SecretStr保护，复用QwenWebRtcSettings校验，错误不携带原context。
- [x] 补.env.example空凭证与候选型号/配置标签，真实.env只保留私有值，不引入自动启用开关。
- [x] 跑目标及静态检查；实际私有文件仅布尔核验，默认create_app仍三Unavailable；检查runtime源码变更对应回归，不重标历史API991或客户端检查。
- [x] 独立只读复核、保留开工文件、更新HANDOFF/运行说明与本轮证据，清临时文件。下一步受控退出验证仍须满足既有可信终止/费用边界。

最终目标194、API1004/191.98秒零skip、Ruff110/锁/metadata/wheel无Key与独立13项审查通过；开发21表全行保留，实际私有配置离线检查通过、零供应商推理。见[验证](../../development/2026-10-25-qwen-private-config-verification.md)。
