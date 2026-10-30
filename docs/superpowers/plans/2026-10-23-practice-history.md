# 本人练习历史与详情实施计划

> 执行使用superpowers:executing-plans。沿用持续开发授权及当前含前置实现的功能分支；不新建缺少未提交底座的worktree，不提交/推送/部署。

**Goal:** 首页可进入本人多次练习，分页、详情、保存文字和复盘真实查询可用。

**Architecture:** 独立只读摘要接口，Flutter账号绑定的单飞读取；已有文字/复盘继续独立核验。采用[本单元规格](../specs/2026-10-23-practice-history-design.md)。

**Tech Stack:** 现有Flutter/Riverpod/go_router、FastAPI/SQLAlchemy/PostgreSQL，依赖不变。

## 1. 摘要查询与分页

文件：新增`services/api/src/simontalk_api/practice_history.py`、`history_routes.py`、`services/api/tests/test_practice_history.py`；修改`main.py`、`models.py`并新增索引迁移。

- [x] 先写真实DB/HTTP测试：空态、本人/跨账号、同时间10+1边界、插入和删除边界后seek、非法limit/cursor、原难度快照、sealed/unknown、不含正文及全表零写入，观察404 RED。
- [x] 单SQL select摘要列并outerjoin completion、EXISTS连接占用；游标`[str(user_id),created_at.isoformat(),str(id)]`base64url编码并严格复验；按tuple seek LIMIT limit+1。
- [x] 注册独立前缀路由，建`practice_history_owner_seek(user_id,created_at,id)`索引；目标pytest全绿后检查Ruff、迁移降升与metadata/查询计划。

## 2. Flutter模型和读取

新增`apps/client/lib/features/history/history_models.dart`、`history_repository.dart`、`history_controller.dart`、`history_providers.dart`；测试位于`apps/client/test/features/history/`。

- [x] 先测owner/字段/排序/重复/游标末项一致性、只GET及X-Account-ID、错误原子拒绝；先RED后实现不可变页和详情。
- [x] `HistoryController.refresh/next/previous`每次8秒及独立fork API，单飞、dispose/账号门、迟到拒绝；分页错误保留旧页且不前进，刷新清空；身份/404/非法响应清空。使用MockClient模拟不可控网络，真实解析和控制器参与测试。

## 3. 页面与导航

新增`history_screen.dart`、`history_view.dart`、`history_previews.dart`；修改`app.dart`、首页view/screen；测试路由和预览。

- [x] 先测首页“记录”→列表→详情→文字/复盘→返回原页，深链接/恢复/未选难度/错误/身份变化；用原app测试装配观察RED。
- [x] 接`/history`和`/history/:sessionId`只读地址、账号恢复保留；复用原文字/复盘push，无自动写入。
- [x] 列表导航使用Wrap；10项有限Column、文本换行与语义按钮；补浅深/320/375/横屏/200%/减动效预览及widget验收。

## 4. 验证与交接

- [x] 目标→API/Flutter全量，分析/格式、Node58、Web release及字体检查；运行命令见本地开发文档。
- [x] 独立临时库/账号/fixture默认关闭网关，真实HTTP多页、同时间、跨账号、重启、零写入；Dart wire读真实后端，生产库不加练习。
- [ ] 浏览器实际点导航/分页/深链接刷新/返回/键盘与窄屏；Preview实际打开。保存截图并记录真实证据和未测范围。
- [x] 清理临时库、凭证、进程和标签，核对开发库与原工作区；更新HANDOFF、基础路线、交互/技术/验证/本地开发及报告。

结果见[验证报告](../../development/2026-10-23-practice-history-verification.md)。实际浏览器/Previewer因Work设置禁用未执行；五态组件渲染及自动测试通过，待补项保留，不用组件截图代替点击验收。
