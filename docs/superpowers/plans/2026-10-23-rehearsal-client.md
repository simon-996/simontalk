# 一级重练客户端实施计划

按writing-plans制定，inline执行（沿用持续开发授权），TDD及独立审查。范围见[设计](../specs/2026-10-23-rehearsal-client-design.md)，后端/依赖/原生不改。

- [x] 基线：读取规格、核对Git/无CodeGraph、保存现有文件摘要；运行既有复盘/历史/入口目标测试。
- [x] `test/features/rehearsal`先写目标与准备包装模型/前文/限额/owner/回复一致性测试并观察RED；新增`lib/features/rehearsal/rehearsal_models.dart`及本人仓库，严格不变结构，复用PracticePreparation。
- [x] 控制器测试先RED：只读/明确固定创建、单飞、CSRF总截止、未知同key同body、来源/账号失效/晚到/取消；新增`rehearsal_controller.dart`，GET/POST使用独立fork且8秒，缺确认不写。
- [x] 页面/导航先RED：两条深链接、未设难度/重连保持地址、默认GET、选择难度/准备/放弃、重练详情只读、返回与复盘ordinary入口；新增view/screen/providers，更新app/review/history小范围接线。
- [x] 新增浅/深320大字/不可用/未知Preview与widget/选择/布局测试，真实渲染查看；修布局需先复现。
- [x] 真实隔离HTTP及Dart wire：有效来源、默认503、原请求丢回复复用、安全放弃、第二次同级、纯读零写、账号隔离/源失效；不调用模型。
- [x] 目标与Flutter全量/分析/格式、Node/Web/字体验证；独立审查修复并复审。后端未改不重跑709为本次证据。
- [x] 尝试实际浏览器与Preview；受限如实记录。更新HANDOFF/对应规格/验证/操作入口，开发库schema与20表全行/依赖保留，清理所有临时环境，未提交/推送/部署。

最终：[验证报告](../../development/2026-10-23-rehearsal-client-verification.md)。Flutter938/8skip、实际wire1、Node58、分析/194格式、Web36.5秒/字体通过，独立复审无确定问题。浏览器/Preview工具禁用，实际页面验收待补；后端、依赖及开发20表/head不变，临时环境已清理。
