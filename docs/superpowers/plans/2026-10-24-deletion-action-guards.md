# 删除页点击资格修补计划

> **For agentic workers:** 使用superpowers:executing-plans在当前会话逐项执行，遵守既有持续开发授权；保留当前分支与原改动，不提交、推送、部署。

**Goal:** 删除页的旧按钮不能在账号忙碌、身份/控制器/已展示范围变化后发起动作，保留与重试沿用既有安全边界。

**Architecture:** 复用HistoryScreen的点击时资格核对模式。资格只在页面层补齐，控制器的8秒截止、单飞、原key/body、未知核对和成功清理保持原契约。确认还绑定本次实际展示的不可变scope，不能由旧按钮确认后来读取的另一范围。

**Tech Stack:** Flutter、Riverpod、go_router；真实页面/provider/controller及MockClient可控HTTP。

## 方案与边界

沿用[删除契约](../../architecture/2026-10-23-practice-deletion.md)的明确确认与账号隔离；本单元不是新增产品选择。只禁用按钮不足以挡住重建前旧回调，因此同时核对最新状态；只靠控制器owner校验无法识别账号busy、页面已经切换或已展示范围变化。页面层保存本次展示值并在激活时复查，避免改变原请求重放协议。

## 执行

- [x] 记录工作区摘要、运行删除页原17项基线；不调用API或数据库。
- [x] 在`apps/client/test/features/history/deletion_screen_test.dart`捕获真实DeletionView的旧回调，先RED验证：账号busy/非登录/新owner、provider失效、scope重新读取后旧确认不请求；go/push切路由后旧确认/保留无动作；删除进行中旧保留不离页；核对/重试/读取遇账号busy不请求。断言请求数、路由与原key/body。
- [x] 在`apps/client/lib/features/history/deletion_screen.dart`定义点击资格：

  ```dart
  final current = ref.read(accountControllerProvider);
  // mounted、当前Route与最新URI目标、signedIn、!busy、当前owner、当前provider与c相同、!c.busy。
  // 确认另验当前ready及identical(c.scope, displayedScope)。
  ```

  所有业务回调使用该门；未知核对/重试还核对当前unconfirmed/canReplay。保留不绕过操作中的离页限制。View与PopScope同时消费账号busy，状态反馈准确区分删除、读取及其他等待。
- [x] 先运行目标回归，检查有效新确认/原请求重放/正常保留仍工作；沿用独立四态Preview，不把夹具当真实供应商结果。
- [x] Flutter全量、分析/格式、Node桥接、Web release与本地字体检查；命令均`--no-pub`。客户端变更不重跑API720或真实wire作为本轮结果。
- [x] 独立只读代码审查；更新删除契约、交互规格、验收矩阵和HANDOFF，核对新增/改动归属与本地链接；清理临时快照。

实际浏览器工具仍被Work设置禁用时保留待验，不启动无法操作的浏览器/Preview服务；模型与原生继续关闭。

结果：原17项基线通过；初11项观察7失败，初审另4项路由全部RED，补1无效地址边界，共新增16。最终目标50、Flutter1043/9skip、Node58、分析/206格式、Web36.2秒/完整字体通过，复审无剩余确定缺陷。详见[验证报告](../../development/2026-10-24-deletion-action-guards-verification.md)。
