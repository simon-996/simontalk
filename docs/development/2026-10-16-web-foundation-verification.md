# Web首屏与键盘操作验证

日期：2026-10-16（Asia/Shanghai）。范围为阶段2的Web基础完善；原生构建继续暂停，语音尚未接入。

## 本轮行为

- Flutter首帧前显示本地HTML品牌与加载文字，使用系统字体，避免先等待应用字体才能解释加载状态。
- 15秒后仍可继续等待，也可主动重新加载；没有虚构百分比，没有自动重放账号请求。
- bootstrap/主入口脚本下载或执行失败、引擎初始化失败、runApp失败，均提供可读错误与重载入口，不向页面展示原始异常。
- Flutter真实首帧后移除HTML加载层；首帧后的无关错误不会重新覆盖应用。保留本地CanvasKit和字体回退配置，并把配置明确传给自定义initializeEngine回调。
- 难度卡片改为标准RadioGroup/RadioListTile，保留原视觉和文案。Tab进入已选项，方向键切换，Tab离开整个组；本地草稿仍需明确保存才PATCH，保存时全部控件禁用。
- 页面和分节有heading语义，难度有互斥checked语义；补充浅/深色窄屏大字号组件预览。

## 自动检查与先失败证据

| 检查 | 结果 |
| --- | --- |
| `flutter test --concurrency=1` | 28项通过；原21项加标题、互斥语义、方向键保存以及注册/重设的4种尺寸组合 |
| `node --test test/web/startup_test.mjs` | 10项通过；运行实际启动代码，DOM和Flutter loader使用明确替身 |
| `flutter analyze` | 无问题 |
| Dart格式与`git diff --check` | 通过 |
| Web release、本地资源模式 | 构建通过；Wasm dry run通过，未验收正式Wasm运行 |
| CI YAML | Ruby Psych解析通过；增加Node启动测试，未推送、未运行远端CI |

修改前，标题header期望得到false、互斥checked期望得到none、方向键后没有草稿变化，3项回归均失败；首帧移除的Node用例也先失败。独立复核又发现主入口错误未被loader回调捕获，新增下载/执行失败2项用例先失败，补全资源error及ErrorEvent.filename识别后通过。

表单新增覆盖：320×568、844×390，200%文字和220逻辑像素键盘遮挡，注册/重设空表单校验后仍可滚动到完整提交按钮，无布局异常。这是widget约束验证，不能替代实体手机软键盘。

## 真实浏览器检查

使用应用内浏览器的独立后台标签，保留用户原标签与输入。正常服务为7357/API8000；故障服务仅绑定本机，未修改CORS或鉴权。

1. 7358故意使bootstrap返回404：立即出现失败文字与重载按钮，点击后实际重新加载。
2. 7359延迟bootstrap约35秒：可见初始加载状态；再次检查可见“仍在加载”及重载按钮。最终可进入Flutter页面，证明首帧移交；该故障端口不在API允许来源中，其后API拒绝属于预期隔离。
3. 7360故意使main.dart.js返回404：修复后立即进入失败界面，而非仅提示继续等待。
4. 7357最终构建：390×844下，用户名Tab进入密码、Enter登录成功；AX树有heading与radio，Tab进入已选项，Right选中下一项，Tab离开组并到达后续开关/保存，Space提交。
5. 保存期间radio与开关均为disabled；刷新恢复保存的难度。之后把测试账号还原为原难度并保存、退出成功。服务端收到实际POST200、PATCH200、刷新GET200与退出204。
6. 检查320×568和844×390；页面横向scrollWidth等于视口宽度，未见截断或溢出。正常流程未捕获浏览器warn/error。所有测试标签与故障服务已关闭，视口已恢复。

截图：[慢加载手机视口](screenshots/web-startup-slow-mobile.jpg)、[bootstrap失败](screenshots/web-startup-failure.jpg)、[入口失败](screenshots/web-entrypoint-failure.jpg)、[方向键焦点](screenshots/web-keyboard-difficulty-mobile.jpg)、[已保存的偏好](screenshots/web-preferences-polished-mobile.jpg)。

## 独立复核

只读审查当前代码与安装SDK实现，发现并修复两项P2：回调模式未转发main.dart.js资源失败；加载层的aria-busy祖先可能压住状态宣告。已移除busy，失败状态的alert与aria-live一致。复核修改后未发现新增P1/P2，独立Node10项通过。审查未运行浏览器，浏览器证据来自上述独立操作。

## 首屏资源基线与剩余范围

下表为未压缩产物大小，**不是一次真实网络传输量或首屏耗时**；CanvasKit实际选择的变体与缓存还会影响下载。

| 文件 | 字节 |
| --- | ---: |
| NotoSansSC.ttf | 17,772,300 |
| Roboto.ttf | 488,584 |
| main.dart.js | 2,693,577 |
| 完整CanvasKit wasm变体 | 7,284,602 |

安装SDK的CanvasKit字体加载会等待FontManifest所列字体下载。当前中文字体约17.8MB，是下一轮首屏性能工作的明确对象；本轮改善状态与恢复，没有声称字体负载减少或大陆网络性能达标。

组件Previewer实际尝试：离线首次生成因缺少缓存的Web预览依赖失败，残留脚手架导致下一次缺包；清理本轮临时脚手架后在线生成，`--web-server`编译与启动成功，但实际界面显示“No previews detected”，生成的预览注册列表为空，不能记为组件预览验收通过。没有修改SDK或手工伪造注册列表。已停止预览进程并清理本轮生成的`.widget_preview`；源码中的浅/深色大字号预览定义保留。此工具问题留待单独定位；页面本身由widget与真实浏览器验证。

真实Android Chrome、Safari、VoiceOver/TalkBack、真实200%浏览器缩放/软键盘、大陆网络首开仍待验证。应用内浏览器的视口和AX检查不等于这些组合已经受支持。旧预检后传输中断本轮未复现，根因仍未确定。

后端未改，沿用上一批42项检查记录；没有模型调用、Android SDK/Gradle下载或APK构建、推送和部署。当前可用能力仍为账号与偏好。
