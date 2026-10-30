# Saved Transcript and Quote Location Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development, task-by-task with independent specification then quality review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 从实际复盘建议定位原用户话轮，并分页查看同一封存输入的全部已保存文字。

**Architecture:** 一个本人sealed只读投影端点，复用原source/hash/result门；一个独立账号阅读客户端与可刷新路由，纯视图和预览分离。详细字段/分页/播放边界见[设计](../specs/2026-10-22-saved-transcript-design.md)。

**Tech Stack:** FastAPI/SQLAlchemy/PostgreSQL17、Flutter/Riverpod/go_router/http；现有主题/字体，无新依赖或迁移。

---

复用当前dirty功能分支（不是main），保留已有全部工作；用户持续授权取代通用逐项审批/commit步骤。本轮不提交、推送、部署、调用实际模型或构建原生。实施agent独占对应代码与工具链，root维护文档及独立fixture；后端使用simontalk_test时root不建该库fixture，实际浏览器另设隔离库。

### Task 1: 只读封存分页与有效建议定位

**Files:** Create `services/api/src/simontalk_api/saved_transcripts.py`、`saved_transcript_routes.py`及`services/api/tests/test_saved_transcripts.py`；Modify `services/api/src/simontalk_api/main.py`仅注册新router。如确需小型公共验证helper，先说明，不重写旧source/result安全门。

- [x] 写并实际运行首个未实现端点RED（真实sealed fixture、本人GET应200而当前404）。

```python
def test_sealed_text_is_readable_without_review_job(client, sealed_practice):
    response = client.get(sealed_practice.saved_path, headers=sealed_practice.headers,
        params={"input_revision": 1, "input_hash": sealed_practice.input_hash})
    assert response.status_code == 200
    assert response.json()["items"][0]["final_text"] == sealed_practice.user_text
```

- [x] 实现既有sealed和_load_sources完整核验后的分页投影（源预算32/8192/4MiB、每页16、响应512KiB）；所有字段严格按设计，空最新修订/多连接顺序不串；纯GET不写input/job/action或媒体。

入口`read_saved_transcript(db,user_id,session_id,input_revision,input_hash,offset,limit,review_item_id)`先执行既有完整校验，再按设计派生/分页，查询默认值由route提供：

```python
from simontalk_api.errors import APIError
from simontalk_api.review_inputs import _completion, _load_sources

completion = _completion(db, user_id, session_id)
if input_revision != 1 or input_hash != completion.input_hash:
    raise APIError(409, "saved_transcript_changed", "保存来源已变化，请重新读取。")
sources = _load_sources(db, completion)
```

- [x] 按设计实现AI final/有效prefix/旧revision/revoke/not_played/unknown/playback-only，focus只来自原有效item和真实user版本，不能由quote猜句；错误无正文。
- [x] 增补鉴权/错绑定/无job/分页/空/多scope/播放/篡改/删改/预算/零写回归；目标、完整API、Ruff/格式通过后给准确证据并释放后端测试库。root依次独立规格、质量审查，有问题先RED修复再复审。

Task1证据：48项新增目标通过；实施agent完整API555/126.40秒，root另跑555/114.96秒，Ruff及76文件格式、metadata/head通过。独立规格和质量审查依次通过，无须代码返修。质量审确认已有非成功job定位409合理，设计已明确无job/有效成功结果不含item404。隔离真实HTTP已验23段/2scope/同turnUUID、第19段精确定位、空最新修订/旧prefix/rev0、无job普通读取及零新增业务记录；客户端与浏览器仍待后续。

### Task 2: 原账号分页阅读客户端、路由与界面

**Files:** Create `apps/client/lib/features/transcript/` 下 `saved_transcript_models.dart`、`saved_transcript_repository.dart`、`saved_transcript_controller.dart`、`saved_transcript_providers.dart`、`saved_transcript_screen.dart`、`saved_transcript_view.dart`、`saved_transcript_previews.dart`和独立preview fixtures（按职责可合并小文件）；Modify `apps/client/lib/app.dart`及review的screen/view/入口回调，以及`lib/core/api_client.dart`仅增加默认不启用的可选实际响应字节上限，供新仓库在解JSON前拒绝超大body（含空白）。Create `apps/client/test/features/transcript/`对应模型/仓库/协调/视图/路由/预览测试，追加review入口/返回滚动及旧ApiClient默认行为回归。

- [x] 先真实RED：已确认sealed复盘能“查看已保存文字”，成功item有“定位到对话”，非sealed/账号错误/busy无操作；实际缺少按钮失败后再写实现。

```dart
testWidgets('sealed review opens saved text without a model result', (tester) async {
  await tester.pumpWidget(reviewWithSealedSourceAndBlockedJob());
  expect(find.text('查看已保存文字'), findsOneWidget);
});
```

- [x] 严格models/本人GET仓库：UTF-8/nullable/枚举/offset/连续ordinal/cursors/source/focus/512KiB和跨页固定锚；构造零请求。controller初读/刷新GET来源→GET页共8秒，分页独立8秒，单飞/取消/账号清理；翻页网络失败保留原页、失效清全部。
- [x] 路由`/practice/:sid/transcript`与`.../transcript/:itemId`只含UUID，incoming encoded阅读路径覆盖恢复/失联/历史，非法零HTTP；进入纯读、返回复盘保留建议位置。source/item点击时复核当前值。
- [x] 纯view按设计分角色/最终文字/AI已播片段与展开生成文字；目标为首段且明确标记，分页/回原话/错误/空/缺口来自真实数据。稳定动作区、48按钮、可选长文本/heading及有限状态播报，不强制抢焦点。
- [x] 新隔离浅/深320 200%/空错误预览；目标/完整Flutter、analyze/格式通过，释放Flutter后规格再质量审查，有问题先RED修复。

Task2证据：新增8个生产/8个测试文件（其中测试夹具独立），完整Flutter773/4原有skip，最终实施20秒、root29秒；VM及Chrome目标各163，root最终Chrome163/29秒。分析无问题、148格式0改动。真实入口/初读metadata/合法空白prefix的RED已修；Chrome额外RED定位1.0的Web数学整数表示，仅改测试为跨平台非整数及VM专有1.0断言，产品代码不变。独立规格后质量审查通过；质量未逐行读测试辅助fixture且不运行工具链，运行证据由root另验。root真实HTTP控制器3项通过，只有GET；Web和实际浏览器继续Task3。

### Task 3: 主任务最终验证与交接

- [x] root独立API/metadata/Ruff与Flutter/Chrome/Node/analyze/格式/Web/完整字体，按最终源码记录，不用前批701/507代替。
- [x] 独立测试库真实HTTP准备23段/两连接/重复turnUUID/空修订/AI旧partial与unknown、真实有效item，焦点19/epoch2及无job读、错误门和13表全行不变；真实Dart控制器3项互通、模拟分页失败留原及账号404不发第二GET，只有GET/0额外生成。四个纯视图离屏渲染实际查看浅/深320 200%/空/错误，固定样例性质明确。
- [ ] 实际浏览器从复盘定位正确scope/版本、前后页/从头回看、返回保留位置、网址刷新/历史/断网/账号清理；实际Previewer点击与字体。当前浏览器工具因Work设置禁用直接拒绝打开，未创建标签、未执行这些流程；Chrome测试/离屏渲染不替代。后续可用时重新建隔离夹具补验。
- [x] 清理临时账号/邀请/库/凭证/脚本/API/Web，未创建本轮Preview/浏览器标签；默认开发库17表/head保持、默认API健康、锁文件与空白检查。更新HANDOFF/交互/技术/路线/验证/新架构与报告、所有本地链接；明确实际浏览器验收及真实模型/重练/完整历史/删除尚未完成。

Task3已有证据：rootAPI555/114.96秒、Flutter773/4原skip/29秒、最终Chrome163/29秒、Node58、分析/148格式、Ruff/76格式及metadata；隔离构建37.2秒、恢复默认API8000构建39.7秒及两次完整字体校验通过。代码单元与可执行检查已完成，实际浏览器/Preview验收保留未勾选，不标完整产品验收。
