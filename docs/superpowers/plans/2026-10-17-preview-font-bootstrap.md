# 组件预览本地字体修复

使用systematic-debugging与TDD，在当前功能分支执行。用户已授权持续推进，无需再次确认。

根因证据：默认Previewer本轮已发现6项预览（旧的空注册问题未复现），但截图没有中文/按钮文字；预览入口不执行应用main，NotoSansSC未注册，继承的本地回退路径连续404。SDK与生成文件不修改，不使用外部字体服务。

采用公开的Preview wrapper，在子组件构建前加载并校验项目本地字体。相比把Noto直接注册到pubspec（会改变正式应用的摘要校验前加载行为）或改生成脚手架（不可维护），wrapper只改变预览入口。共享字体加载器增加包资产前缀与可选别名，默认正式入口保持原路径与摘要校验；预览器自身Roboto字体别名使用同一份已校验Noto数据获得中文覆盖，仅在预览进程生效。

- [x] 新增`test/design/preview_surface_test.dart`，观察字体未就绪不构建子树、成功后展示、失败显示诊断；先失败再实现。
- [x] 新增`lib/design/preview_surface.dart`，公开`previewWithFonts` wrapper与Future gate；六处Preview使用它。
- [x] `core/app_fonts_web.dart`与native签名接受可选`assetPrefix`，Web仍校验长度/摘要；预览使用`packages/simontalk_client/`。
- [x] Flutter定向/全量、分析、Node与Web构建验证；真实Previewer截图确认中英文及六项预览可见。
- [x] 更新本地开发、验证记录与HANDOFF，清理本轮生成脚手架/停止进程，本地提交。
