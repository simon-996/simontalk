# 最终文字客户端读取 Implementation Plan

> **For agentic workers:** 使用 superpowers:subagent-driven-development 分离纯模型/读取、控制器接入和UI验证，独立审查后收尾；用户已授权自主继续。

**Goal:** 在现有恢复入口安全读取原连接的最终文字，展示当前修订和未知播放边界。

**Architecture:** 不可变事件/分页/追加历史负责核验；PracticeRepository仅GET；恢复控制器串行受账号约束；独立惰性读取组件接入既有面板。

**Tech Stack:** Flutter、Dart、Riverpod、http，沿用PostgreSQL/FastAPI现有GET。

---

## 1. 模型与仓库

文件：新建 `apps/client/lib/features/conversation/final_transcript_read_models.dart`、`apps/client/test/features/conversation/final_transcript_read_test.dart`、测试fixture；修改 `apps/client/lib/features/practice/practice_repository.dart`。

- [x] 先写 `FinalTranscriptPage.fromJson(json, scope: scope, afterSequence: 0, limit: 32)` 与 `FinalTranscriptHistory.empty(scope).append(page)` 的身份/修订测试，运行缺失API的RED。
- [x] 按[设计](../specs/2026-10-20-final-transcript-read-design.md)实现三个不可变final类和GET方法；以原scope重建，先核验整批再返回新history。补齐严格输入/统计/跨页映射/预算/Unicode日期错误与无副作用测试并跑目标GREEN。

## 2. 恢复控制器

文件：修改 `apps/client/lib/features/practice/practice_recovery_controller.dart`；新建 `apps/client/test/features/practice/final_transcript_recovery_test.dart`。

- [x] 先测试 `refresh()` 后 `loadTranscripts()` 只GET原连接、分页后低revision/重复ID不更新history，运行RED。
- [x] 增加transcripts/error/loading/getters、互斥读取/刷新操作及生命周期清理；用`repo.loadFinalTranscripts`读取，`history.append`原子发布。翻页失败保留cursor，refresh清空，401/409账号/404删除及时清掉旧正文，dispose立即取消；补全8秒与晚响应、原账号getter保护。
- [x] 测试provider实际接入与已有恢复/清理用例回归；不修改清理HTTP规则。

## 3. 查看组件

文件：新建 `apps/client/lib/features/conversation/final_transcript_read_view.dart` 与对应widget测试；修改 `practice_recovery_panel.dart`、现有必要panel tests。

- [x] 先写空态、AI未知、修订/缺口、load-more/error/refresh交互及实际panel GET-only测试RED。
- [x] 沿用项目主题，组件参数为history/busy/errorCode/onLoad/onRefresh，惰性入口；当前文字用有界ListView.builder/scrollbar，状态和按钮可访问。加入light/dark样例@Preview（仅预览数据）。
- [x] 测试320×568、844×390及200%字号、长文及键盘，运行真实浏览器/组件预览检查并保留明确证据。

## 4. 审查与交接

- [x] 分别审查核心读取/账号生命周期与UI符合性，修复后复验。
- [x] Flutter全量、analyze、Dart format、Node、Web release/字体通过；实际Dart GET→回环API→测试DB验收，清理临时数据/API。无真实供应商/媒体/原生。
- [x] 更新架构、交互、验证、本地开发及HANDOFF，核对文档链接/`git diff --check`，本地提交本批改动并核对仅余并行文档，不推送/部署。

命令在 `apps/client`：`flutter test --no-pub`、`flutter analyze --no-pub`、`dart format --output=none --set-exit-if-changed lib test`、`node --test test/web/*_test.mjs`、`flutter build web --release --no-pub --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000`；根目录字体脚本见本地开发记录。使用已安装SDK绝对路径及既有缓存，测试/构建/预览不并行占Flutter锁。数据库仅独立simontalk_test，开发库只读核对。
