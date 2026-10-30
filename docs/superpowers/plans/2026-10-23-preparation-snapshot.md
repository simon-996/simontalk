# 普通准备的难度快照与点击资格

2026-10-23，持续开发授权下修补未确认准备/恢复衔接；按systematic-debugging/TDD在现有分支执行，保留原工作，无提交/推送/部署。

## 已定位风险与方案

PracticePreparationController固定原难度/key/body，但PreparationScreen总显示当前全局偏好。偏好更新时，未确认/已登记准备可能显示新难度而仍确认旧请求。准备前current读取期间也需保留点击时的难度，尚未登记且预检失败后则回到最新偏好。

Entry保存本次明确点击的难度，显示优先服务端已知practice配置，其次本次请求快照，尚无请求时才用当前偏好。快照不改变全局偏好/原key/body，不落盘；账号变化/销毁不再暴露。预检未进入准备时释放快照，已有未确认请求/停止过程保留。

首页进入准备、准备的开始/确认原请求在点击时重读账号/忙碌与原owner。新开始还校验偏好未变及当前canStart；确认原请求允许偏好更新，但仍用原请求。取消/离页沿既有安全cleanup路径，不新增重新登记或媒体行为。

## 步骤

- [x] 阅读HANDOFF/Git/准备和恢复；保存619个原文件摘要，先运行原Entry/Screen/Preparation基线。
- [x] 现有`practice_entry_screen_test.dart`先写RED：未知回复后偏好改变、已登记后偏好改变、预检中变化与失败回退；核对标题和真实原key/body。再复现重建前账号busy/偏好变化/新占用时旧按钮的动作。
- [x] `practice_entry_controller.dart`增加请求难度快照及只读显示getter，在begin冻结、预检未登记的finally释放；Screen使用该快照。
- [x] `practice_entry_screen.dart`在首页进入准备/新开始/原请求确认点击时复验当前账号、owner/busy及资格。新开始拒绝已改变的显示难度；原请求确认不套用新偏好。PreparationView标题说明本次难度，首页仍为当前难度。
- [x] 运行目标/全量Flutter、分析/格式、Node、Web/字体；独立只读审查。所有Flutter命令`--no-pub`，无后端/API/DB/依赖及实际wire变化。
- [x] 更新验证/交接/契约，核对原文件、依赖/后端摘要、本地链接与空白；浏览器工具不可用则实际验收待补。

结果见[验证报告](../../development/2026-10-23-preparation-snapshot-verification.md)。既有practice_entry_previews_test按首页/准备分别核验标签；浏览器禁用，实际验收继续待补。
