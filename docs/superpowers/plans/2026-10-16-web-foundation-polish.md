# Web首屏与键盘可访问性实施计划

**Goal:** 按已批准的视觉与交互规格，让Web加载有真实状态与失败恢复，难度选择支持标准键盘操作，补齐窄屏表单验收。

**Architecture:** 保留Flutter/Riverpod和现有账号API。首屏用极小的本地HTML在Flutter首帧前提供状态；真实首帧后移除，失败只提供用户主动重新加载。难度卡片沿用颜色、间距、文案，使用Flutter自带RadioGroup/RadioListTile承接互斥语义和方向键行为。不开启新平台构建，不调用模型，不改鉴权。

**Tech Stack:** Flutter3.47.5、Dart3.13.4、原生HTML/CSS/JavaScript、Node内置test runner。

## 1. 难度与标题语义

- [x] 在`apps/client/test/features/account/account_flow_test.dart`加入回归：标题header、已选难度checked/互斥、方向键选择并仅在保存时PATCH。
- [x] 先运行新增用例，确认当前普通按钮无法满足预期，3项失败后修复。
- [x] 修改`preferences_screen.dart`，用RadioGroup包裹原卡片、RadioListTile代替图标与InkWell；禁用状态由原busy控制，设置仍需保存才提交。
- [x] `account_components.dart`的PageIntro与设置分节添加heading语义；加入浅/深色窄屏预览定义。实际Previewer显示“No previews detected”，未算渲染验收通过，详见验证记录。
- [x] 核对注册与重设表单在320宽、200%字号、横屏和模拟键盘遮挡时仍可滚动到提交操作；4种组合通过，没有额外改动现有表单布局。

## 2. 首屏状态与失败恢复

- [x] `apps/client/test/web/startup_test.mjs`用Node VM运行实际启动脚本：首帧移除、慢加载可等待/重载、脚本下载失败、引擎初始化失败、App启动失败、正常移交配置和首帧后的无关错误。补主入口下载/执行失败后共10项。
- [x] 先失败，再实现`web/index.html`与`web/flutter_bootstrap.js`。保持本地CanvasKit/字体配置；自定义回调明确把同一配置传给initializeEngine。
- [x] 加载区使用原品牌绿色、系统字体、文本状态、可见焦点与reduced-motion。无虚构百分比；首次用户页面出现后不残留遮罩；无JavaScript时有可读说明。
- [x] 将Node测试加入现有CI，不新增应用依赖。

## 3. 验证与记录

- [x] Node10项、Flutter28项、分析、格式与Web release构建通过。
- [x] 后台独立浏览器标签检查桌面/手机视口、键盘、成功加载；独立故障服务验证bootstrap与main.dart.js的404，保存截图；测试标签与服务关闭，用户原标签保留。
- [x] 记录当前首屏资源大小与字体等待机制；没有冒充大陆网络性能或实体手机/屏幕阅读器验收。
- [x] 更新HANDOFF和本地运行/验证文档，保存在本地功能分支，不推送、不部署。

依据：既有视觉/交互规范；[Flutter启动文档](https://docs.flutter.dev/platform-integration/web/initialization)；安装SDK中的RadioGroup、CanvasKit字体加载与首帧事件实现。
