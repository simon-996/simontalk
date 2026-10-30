# Saved Status Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement task-by-task with specification and quality review. Steps use checkbox (`- [x]`) syntax.

**Goal:** 在真实恢复入口查看服务器保存结果、具体缺口及连接待核验状态。

**Architecture:** 新增原scope只读termination-check、严格模型及仓库端口；恢复控制器一次受限读取两种状态，原子发布；独立展示组件接入原页面，不触发媒体或新写入。

**Tech Stack:** FastAPI/SQLAlchemy/PostgreSQL；Flutter/Dart/http/Riverpod、Widget Preview、既有语义主题。

---

完整wire和文案依据[设计](../specs/2026-10-21-saved-status-recovery-design.md)。所有既有未提交改动保留，工作区复用；不提交/推送/部署，不调用供应商，不恢复原生。

### Task 1: 原连接核验状态只读端口

**Files:** `services/api/src/simontalk_api/termination_checks.py`、`completion_routes.py`和新`tests/test_termination_check_read.py`；客户端新`termination_check_models.dart`、仓库及新模型/仓库测试。

- [x] 先写`assert client.get(path(...,'/termination-check'),headers=...).status_code==200`，运行新测试观察缺路由失败；新增严格模型/仓库端口失败用例。
- [x] 实现单SQLleft join返回设计限定字段、准确not_requested/blocked关系，读取前后连接/任务/租约不变；他账号和删除404，登录撤销/账号头隔离，错误不含attempt摘要。
- [x] 严格Dart scope/日期/状态解析，仓库只GET；运行目标API及Dart tests、ruff/analyze/format。该任务独占测试库直至通知root，勿与真实wire并行清库。

### Task 2: 串行读取、原子发布和账号生命周期

**Files:** `practice_recovery_controller.dart`和新`test/features/practice/saved_status_recovery_test.dart`。

- [x] 先RED：`await controller.loadSaveStatus()`后可见真实summary及termination；未登记准确404、第二GET失败不发布部分结果、无connection不请求、刷新先清旧状态、总8秒截止与账号变化/晚响应清除。
- [x] 新operation及受账号限制getter，使用已有_read一次包两至三GET；历史origin独立核对、追加HTTP前截止门及已知end保留门；不改现有文字/观测/清理语义，不自动请求或轮询。运行目标和原恢复回归。

### Task 3: 状态组件、页面接入及预览

**Files:** 新`practice_save_status_view.dart`与对应widget tests，修改`practice_recovery_panel.dart`。

- [x] 先RED未查询/载入/未登记/ending/sealed完整和缺口/失败/blocked文案与按钮，纯GET刷新，无恢复/保存写动作；窄320/375、深浅色200%字号无overflow、键盘触达/语义。
- [x] 实现设计分组原因、独立连接说明和刷新操作，接原controller；完成主题/尺寸预览，不改文字滚动/选择区。
- [x] 运行widget+恢复回归，预览和实际浏览器查看主题/宽度/焦点，发现问题再修。

### Task 4: 真实验证、复核与交接

- [x] 独立测试库实际HTTP/浏览器验证已固化缺口、blocked需维护、未登记、读取失败/重试和账号隔离；清理临时账号/凭证/服务。
- [x] 规格审查修复并复审，再质量审查；运行全量API/Flutter/Node、分析/格式、Web无CDN/no-pub及字体，锁文件不变、无迁移。
- [x] 新实测报告/接口与交互边界/HANDOFF，检查本地链接和空白。明确current范围不是完整历史，实际语音与可信终止执行器仍缺。


最终证据：[实测报告](../../development/2026-10-21-saved-status-recovery-verification.md)。API394、Flutter609/3skip、实际HTTP1、Node58；真实浏览器失败/重试、A/B隔离及窄屏/键盘通过，Preview深浅色可见。规格复审后独立质量审查通过。临时fixture/服务已清理并恢复默认开发API，未提交/推送/部署。
