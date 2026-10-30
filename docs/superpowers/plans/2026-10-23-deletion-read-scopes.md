# 删除确认后的读取状态清理

2026-10-23，持续开发授权内修补已复现的跨入口遗漏。沿用systematic-debugging/TDD与现有删除契约；保留当前分支和全部原改动，不提交/推送/部署。

## 根因和方案

DeletionScreen在可信删除凭据后清理history/review/transcript读取provider，但后续新增的rehearsal目标、ordinary资格、关联列表与原恢复读取provider未加入。使用真实Riverpod订阅保留这些读取scope，确认删除并回历史后，旧RehearsalController仍暴露目标正文；它们不能依赖页面最终dispose来履行本地清理。

在现有确认成功的同一清理点增加四类provider失效，沿用已有广度，不新建状态总线。仅在可信DELETE或原key凭据确认成功后清理，保留/409/删除动作的未知回复不假设成功。dispose取消在途只读，旧响应不能再发布；新provider构造保持静默，资格FutureProvider如被订阅则重新GET核验。恢复新读取仍可返回content_deleted及unknown占用，清理内容不等于取消连接或结束用量。

不失效PracticeEntry、Preparation或Media provider：它们含清理/媒体生命周期及原请求状态，不能用dispose替代可信终止。恢复/列表为只读；rehearsalProvider还保存创建动作，因此失效会同时结束该控制器的本地目标和未确认key。这沿用成功返回历史后关闭RehearsalScreen的原生命周期与key仅存当前控制器的契约，不承诺额外长期订阅中的无关创建动作继续保留。不会自动发POST、取消准备、重试生成或建立连接。

## 步骤

- [x] 根目录616原文件摘要；基线排除新增复现用例，运行历史/重练/恢复原测试。
- [x] `apps/client/test/features/history/deletion_screen_test.dart`先RED：持有目标/列表/资格/恢复订阅，确认删除后旧target必须null，新scope必须独立，unknown刷新仍保留。已观察旧RehearsalTarget导致断言失败。
- [x] 同文件补在途目标/列表/恢复的迟到响应、未知删除结果保持及随后凭据确认清理、保留/409不清理的回归，先RED后修。
- [x] `apps/client/lib/features/history/deletion_screen.dart`导入practice_providers、rehearsal_providers、rehearsal_list_providers；在既有可信receipt清理点增加`ref.invalidate(practiceRecoveryProvider/rehearsalProvider/rehearsalEligibilityProvider/rehearsalListProvider)`。不调用其他provider的动作。
- [x] 目标/全量Flutter、分析/格式、Node、Web/字体及独立只读审查。所有Flutter命令`--no-pub`；无后端/schema/API变化，不重跑实际wire或API709为本轮结果。
- [x] 更新删除契约/交接/验证，核对原文件、后端及依赖摘要，本地链接和git diff空白；浏览器工具仍禁用则实际验收待补。

结果见[验证报告](../../development/2026-10-23-deletion-read-scopes-verification.md)。独立复核对rehearsal family包含动作这一范围已明确记录；实际浏览器/Preview仍待补。
