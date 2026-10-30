# 复盘供应商配置实施计划

> 当前会话按executing-plans执行；用户已要求连续开发，不逐步等待审批、不提交或推送。

**Goal:** 标准create_app支持默认关闭、显式选择的真实复盘供应商装配。

**Architecture:** qwen_config负责私有参数，review_providers负责模式选择，main只使用装配工厂。后台worker和所有媒体准入边界保持现有语义。

**Tech Stack:** Python3.13、现有Pydantic/HTTPX/FastAPI/PostgreSQL17/pytest；无新增依赖。

- [x] 新增tests/test_review_provider_config.py，先运行pytest观察新loader/工厂/Settings尚缺的失败；覆盖禁用不读私密配置、启用无HTTP、私有错误无context/Key、只允许3.8、环境覆盖和数据库前失败。
- [x] 修改qwen_config.py拆出共享私密基类并新增复盘loader；config.py增加模式及可选私有文件；新增review_providers.py仅按明确合法模式构造；main.py在DB创建前装配。
- [x] 修改.env.example保持disabled，补复盘型号/标签/文件位置；不修改实际.env开关。运行配置及现有适配器目标测试。
- [x] 新增标准工厂的SQL/worker组合测试，覆盖默认blocked、显式配置有效生成/空、未知不重派、配置变更和构造零HTTP。专用数据库运行完整API，备份恢复required=1、真实PG17工具入口。
- [x] 受控标准工厂真实调用只在独立测试库，记录用量/纯读/重启/删除；核对wheel及默认关闭，独立只读审查、Ruff/格式/锁、数据库全行及原文件保留。
- [x] 更新开发/架构/验收/HANDOFF证据，清理本轮库、工具和探针，无提交/推送/部署。语音退出/截断缺口不再重复发同类探针。
