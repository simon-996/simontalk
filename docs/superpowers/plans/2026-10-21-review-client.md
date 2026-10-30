# Review Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development, then independent specification and quality review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将真实封存输入和持久复盘任务接入原账号Dart客户端，可明确创建、纯读与安全重试。

**Architecture:** 独立review目录、严格摘要/结果模型、本人repository和单飞/固定动作client；Riverpod账号family绑定生命周期。页面和媒体不变。

**Tech Stack:** Flutter/Dart、Riverpod3、现有ApiClient/http及flutter_test，无新增依赖。

---

完整[设计](../specs/2026-10-21-review-client-design.md)为验收依据。复用feat/account-foundation现有工作区和dirty；用户持续开发授权覆盖常规选择，不提交/推送/部署/调用供应商/原生。实施agent独占应用代码；root只写文档并在释放后独立验证，不并行启动Flutter工具或测试库写入。

### Task 1: 模型、仓库、客户端和provider

**Files:** 新`apps/client/lib/features/review/review_models.dart`（需要时按输入/结果拆分）、`review_repository.dart`、`practice_review_client.dart`、`review_providers.dart`；新对应`apps/client/test/features/review/`回归和`apps/client/test/integration/review_client_wire_test.dart`。既有ApiClient/PracticeCompletion模型只复用，必要修改先说明；不得改后端/媒体/UI/锁文件。

- [x] 先RED：目标不能由ending建立，sealed目标仅保留原账号/练习/版本/hash；确实观察缺失能力的失败，再实现严格模型。

```dart
test('ending input cannot authorize review', () {
  final ending = PracticeCompletionSummary.fromJson(
    completionSummary(), scope: scope(), endKey: requestKey,
  );
  expect(() => ReviewTarget.fromCompletion(ending), throwsFormatException);
});
```

- [x] 对照实际Python响应建立绑定摘要/九态/0–3结果模型及不可变集合；测试跨账号/输入/job/hash、无效日期/布尔/计数、状态-结果矛盾、超预算/枚举、重复item/ordinal与不合法正文。
- [x] 仓库显式本人read/create/retry路径和精确body/key；先测账号/CSRF/body与invalid_response，再实现。输入只留摘要，结果权限不冒充客户端原话重算。
- [x] client先测纯读无POST、网络失败后key/body固定、单飞、八秒总截止和dispose/账号改变晚到；实现requestReview/refresh/retryGeneration/retryPending与无正文身份/终态锚点。恢复不自动重调，未知/耗尽/非可重试态无写入。
- [x] account autoDispose family监听身份/结果变化，不因构造/监听发HTTP；补隔离/释放测试。运行目标回归、完整Flutter/analyze/format，通过后释放Flutter工具给root。
- [x] 新actual HTTP测试缺`SIMONTALK_REVIEW_CLIENT_WIRE_FIXTURE`时明确skip；支持root提供的隔离API/身份/sealed completion及测试gateway控制文件，测试真实client流与结果，不输出凭证。测试factory/方法协议先通知root，数据库准备与精确清理由root负责。

### Task 2: 两阶段独立复核

- [x] 规格审查身份/绑定、原动作重放、只读、时间/清理、业务态与范围；需修项先RED，再复审。
- [x] 规格通过后质量审查并发/取消、HTTP资源、内存正文生命周期、provider、解析与兼容，修后复审通过。

### Task 3: 主任务验证与交接

- [x] 独立实际HTTP覆盖默认blocked、正常/空/非法建议、无重复调用与隔离，清理临时服务/账号/邀请/凭证；明确fixture性质，无真实语言验收。
- [x] 根任务完整Flutter/analyze/格式、Node/Web release/字体、默认API与开发库未污染、锁文件/空白检查；客户端变更不把前批API506标成重跑。
- [x] 新架构/验证报告与HANDOFF及对应规格同步，检查本地链接/锚点，完成计划；明确正式页面/真实模型等剩余事项。
