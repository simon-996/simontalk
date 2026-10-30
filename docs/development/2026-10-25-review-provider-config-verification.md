# 标准应用工厂复盘配置接入验证

日期：2026-10-25（Asia/Shanghai）。按用户持续开发授权完成[显式供应商配置](../architecture/2026-10-25-review-provider-config.md)，新增后端装配能力；没有重复发语音截断/退出探针。[设计](../superpowers/specs/2026-10-25-review-provider-config-design.md)，[计划](../superpowers/plans/2026-10-25-review-provider-config.md)，[脱敏证据](evidence/2026-10-25-review-provider-config.json)。

## 已实现与检查

- Settings增加默认disabled的review_provider及可选私有文件位置；仅明确qwen模式加载复盘参数，标准create_app在数据库引擎/runner前构造网关。启用仅接受qwen3.8-flash，不将前批语义未通过的旧型号自动投入使用。
- qwen_config共享私密凭据基类，新复盘loader与实时模型参数独立；环境覆盖、SecretStr/repr隐藏、稳定错误无context/cause。未把Key加入通用Settings、API或客户端。
- 默认禁用不读Qwen私有参数/不构造HTTP；启用构造仍零请求，只有合法业务任务进入既有runner。实际私有.env保持原样，不写全局启用开关；默认语音/信令继续Unavailable。
- 23项新纯组件先全RED，之后配置/现有适配器143项通过；4项SQL/worker组合加上既有目标最终164项/7.38秒通过。首轮SQL测试HTTP替身错误使用预消耗content，适配器保守判unknown；核实stream已consumed后改用既有Parts流，不修改生产解析器。
- API全量1042项/191.31秒通过，无skip；required=1及真实PG17工具入口包含两项真实备份恢复。Ruff、113文件格式与38包离线锁通过。schema/依赖/客户端未改。
- 独立只读审查143项/0.32秒通过，无确定功能问题；指出两个旧模块docstring仍称应用永不启用，已修正为默认关闭/明确启用。全量之后仅改这两句说明，不重跑无关全量；wheel按最终源码重建并复核。

## 标准启动路径的真实调用

在本轮独立测试库，以Settings显式qwen模式和已有私有文件创建应用，**没有替换app.state.review_gateway**，也没有手动调用batch来代替后台runner。HTTP观测只在原client上增加请求计数，不替换真实传输或请求选项。

启动构造阶段HTTP客户端/外调均0。先验证语音创建仍503，然后仅在隔离应用使用测试准入登记ASR文字离线重放范围，封存前批真实合成音频所得的正确英文；该业务连接不是原实时会话。

合法复盘排队后，由正常生命周期runner自动执行一次真实qwen3.8-flash调用，返回no_suggestions/attempt_count=1，输入650/输出6 Token已落库。HTTP请求及客户端构造均只有1次，结果没有强凑建议。本人GET及他账号404通过；重建disabled应用且私有文件不存在，仍能纯读同一结果和本人历史；删除后复盘/详情不可读，调用数保持1。全程约3.08秒；没有本轮浏览器UI或实时媒体闭环验收。

这是用户20元首测范围内的一次受控调用，账单未获取；本轮没有新增语音费用观测，不以配置开关或用量字段证明硬停费。

## 打包与收尾边界

最终wheel六份生产源码与工作区一致，不含实际私有Key/.env；实际私有配置离线构造成功，默认Settings仍disabled，私有文件摘要保持原值/0600。开发21表全行摘要与开工一致，专属测试库在0连接时删除，真实恢复库剩余0；本轮临时工具/wheel/日志/探针已清理。开工793文件保留，11份原文件有意更新、782份摘要一致，新增8份；311个本地链接/JSON、19份变更文件与临时文件及解包wheel的私有Key扫描通过，git diff --check通过。

没有提交、推送、部署或原生构建。后续B5仍需真实练习来源、本人页面及更广语言质量；B2仍需可信退出和上下文截断，B6完整实时流程未通过。现有复盘页面复用既有API，无需新增客户端供应商开关。
