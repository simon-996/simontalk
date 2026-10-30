# 通话中页面与通话入口

2026-10-30（Asia/Shanghai）。本轮补齐 B2 清单中唯一不依赖供应商的客户端交付：练习中的通话页面及其入口交接。未连接千问、未申请物理麦克风、未产生费用，正式语音准入保持关闭。

## 1. 交付内容

| 项 | 位置 | 说明 |
| --- | --- | --- |
| 通话页视图 | `apps/client/lib/features/session/practice_session_view.dart` | 只消费 `PracticeMediaPhase`、`MediaPlayback`、`muted` 与错误码，不自行推断连接状态 |
| 通话页屏幕 | `apps/client/lib/features/session/practice_session_screen.dart` | 挂载时启动一次媒体尝试；静音、继续播放、结束、重试保存、查看记录 |
| 预览 | `apps/client/lib/features/session/practice_session_previews.dart` | 听你说、播报中、已静音、结束待保存、语音不可用五项 |
| 路由 | `apps/client/lib/app.dart` | `/practice/session`，只允许从准备页交接进入 |
| 入口 | `practice_entry_view.dart`、`practice_entry_screen.dart` | 准备处于 `reserved` 时显示“进入通话” |

## 2. 关键行为

- **不会提前声称在听**：`preparing`、`connecting`、`configuring` 三态分别显示“正在登记”“正在连接语音”“正在确认语音配置，尚未开始收音”，只有 `active` 且播放状态非播报、非静音时才显示“正在听你说”。
- **静音与播报是两件事**：播报中显示“正在说”；静音后显示“麦克风已关闭”，按钮变为“打开麦克风”；播放被浏览器拦截时单独显示“需要点击继续播放”并给显式恢复操作。
- **收尾不是结束**：`draining` 只显示“正在收尾，等待最后一句识别…”，通话控制全部移除；`localClosed` 显示保存状态（等待回执、正在保存、已保存、失败重试），不把本地释放写成上游已终止。
- **进入通话前先取消预检**：准备阶段的登记是“未开始上游”的预检。点“进入通话”会先 `cancel()` 并等待服务端确认（`PreparationPhase.stopped`），确认后才导航；未确认则停留原地，不会同时存在两条占用。
- **连不上时有明确出口**：`preparing`/`connecting`/`configuring` 显示“连接确认前不会采集或播放音频”和“取消这次尝试”（标题栏另有“关闭”），取消会先停掉这次尝试再离开，不会把未建立的连接写成已结束；收尾阶段才显示“正在收尾”。
- **账号变化不留白**：媒体作用域随账号重建时页面显示“当前登录已变化，这次练习无法继续”，不再渲染空页面。
- **字幕按偏好起、只在本次通话内切换**：初始状态取账号的“默认显示英文字幕”，标题栏“字幕：开/关”立即生效，关闭时对话区显示“字幕已关闭，可随时在右上角打开”，通话控制不受影响；切换不写回账号设置，下一次练习仍按偏好开始。
- **直接访问不会开麦**：`/practice/session` 需要路由 `extra`，浏览器刷新或手输地址会被重定向回 `/practice`，避免无意中创建练习或请求麦克风。

## 3. 验证

客户端检查（`apps/client`）：

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub                        # 无问题
flutter test --no-pub                           # 1513 通过，10 项专用 skip
node --test test/web/*_test.mjs                 # 77 通过
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

本轮新增 24 项自动测试：视图 11 项（状态文案、连接阶段不冒充收尾、静音、播报、阻塞播放、收尾、结束、保存失败重试、字幕开关与关闭态、320 宽 125% 字号、深色）、屏幕 5 项（只启动一次尝试、静音与结束转发、结束后的唯一收尾路径、连接中取消可离开、字幕初始态取自偏好并可即时切换）、预览 6 项，以及入口屏幕 2 项（直接访问被重定向、交接顺序为“先取消预检再进入”）。

后端未改代码，仍按既有契约运行。本轮在 `services/api` 复跑全量：`uv run pytest -q --basetemp=/tmp/simontalk_pytest_full` 得 1172 通过、2 项 skip。首跑时不带 `--basetemp` 出现 107 项 `FileExistsError`，原因是受限沙箱下 pytest 的临时目录创建被拦截，属于运行环境问题；同一批用例换可写临时目录后通过，未据此修改任何源码。

## 4. 边界与未完成

- 真实语音仍不可用：默认协议工厂保持 `unavailableRealtimeProtocol`，正式准入关闭。本轮没有连接供应商、没有真人或设备音频，也没有费用发生。
- 每次通话会先取消一次预检准备，因此服务器上留下一条 `cancelled` 记录。更干净的做法是让媒体协调器接受既有准备，这需要改动 `PracticeMediaCoordinator` 的键与幂等约束，留待接入真实语音时一并评估。
- 未验证：真实播放与人耳输出、自然插话、可信远端退出、设备切换与后台、手机浏览器。B2 与 B6 仍未完成。
