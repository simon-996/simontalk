# 本地开发

当前真实可用范围是账号、练习偏好与Web本机麦克风检查。AI实时语音、反馈、记录及费用尚未接入。2026-10-16用户更新为 **Flutter Web优先**；Android构建与安装验收暂停，保留Android/iOS工程。

## 环境

- Flutter 3.47.5 / Dart 3.13.4；客户端依赖由 `apps/client/pubspec.lock` 锁定。
- Python 3.13、uv；后端依赖由 `services/api/uv.lock` 锁定。
- Docker / Compose、PostgreSQL 17。开发端口 54329，仅绑定 `127.0.0.1`。
- Android 最低 API 24，编译/目标 API 36；安全存储使用 Android KeyStore，并关闭应用自动备份。Android 许可由本人阅读、接受，项目不会代替接受。

以下命令从仓库根目录开始。每个常驻进程使用独立终端。

## 数据库与 API

```sh
docker compose -f deploy/compose.yaml up -d db
docker compose -f deploy/compose.yaml exec -T db pg_isready -U simontalk -d simontalk
docker compose -f deploy/compose.yaml exec -T db createdb -U simontalk simontalk_test
cd services/api
uv sync --locked --all-extras
cp .env.example .env
uv run alembic upgrade head
uv run uvicorn simontalk_api.main:create_app --factory --host 127.0.0.1 --port 8000
```

`createdb` 只在首次运行，已存在的测试库无需重复建立。已有 `.env` 时保留自己的配置，跳过复制。开发库 `simontalk` 与测试库 `simontalk_test` 分离；测试会清空指定 `_test` 库的应用表。

维护命令在 `services/api` 运行：

```sh
uv run simontalk-admin invite
uv run simontalk-admin reset username
uv run simontalk-admin disable username
uv run simontalk-admin expire-connections --limit 100
uv run simontalk-admin cleanup-preparations --limit 100
```

邀请单次 72 小时；重设凭证单次 15 分钟。凭证仅显示一次，不写入 Git。前台不自动发短信、邮件，也不提供远程管理员 API。更多身份与生产配置见 [API 说明](../../services/api/README.md)。

更新后运行`uv run alembic upgrade head`，练习/连接准备均有持久表，当前head为`f80e9c1a24bd`（新增受限连接观测子表及原连接身份复合外键）。API源码修改后须重启本地Uvicorn，启动命令未启用自动重载。真实运行的新练习/连接准入及信令网关固定关闭；测试策略仅用于独立测试库，不能通过环境变量开启没有接入的语音服务。正常API lifespan现每15秒自动执行一批连接租约和300秒闲置准备清理，间隔可由`SIMONTALK_PRACTICE_MAINTENANCE_INTERVAL_SECONDS`设为1–300秒；手动完整批次使用cleanup-preparations。未开始上游可安全终结，上游未知继续占用；进程关闭期间不调度，没有媒体终止能力。详见[准备登记验证](2026-10-17-practice-preparation-verification.md)、[连接租约验证](2026-10-17-connection-reservations-verification.md)、[恢复清理验证](2026-10-17-preparation-recovery-verification.md)、[单次信令验证](2026-10-17-guarded-signalling-verification.md)与[受限观测验证](2026-10-18-connection-observations-verification.md)。

## Flutter Web

开发调试：

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 7357 --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

用浏览器检查正式 Web 产物：

```sh
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000
python3 -m http.server 7357 --bind 127.0.0.1 --directory build/web
```

访问 `http://127.0.0.1:7357`。Web 与 API 必须使用相同主机名，不能混用 `localhost` 和 `127.0.0.1`；Cookie 为 SameSite=Lax，端口可以不同。Web 不保存业务 bearer 到 localStorage，使用 HttpOnly Cookie 与 CSRF。生产建议同源反向代理 `/v1` 和 `/health`，省略 `API_BASE_URL` 时 Web 使用当前来源。

`--no-web-resources-cdn` 加上仓库的 bootstrap 使用本地 CanvasKit；中文字体随应用分发，普通中英文界面不依赖运行时 Google 字体服务。未覆盖字符的本地回退、真实大陆网络首屏性能及缓存策略仍需验收。

Web首帧前有HTML加载状态，15秒后允许继续等待或主动重载，启动资源或初始化失败有重载入口。首帧后由Flutter接管；这些状态不等于已支持离线使用。中文字体已完整压缩为约7.8MB，保留源字体全部30,890个Unicode映射和可变字重；加载前验证长度与SHA-256。WebCrypto要求HTTPS或受信任loopback，不支持局域网普通HTTP。字体工具、数据和限制见[字体说明](../../apps/client/assets/fonts/README.md)与[本轮验证](2026-10-16-web-font-verification.md)。实际大陆网络首开仍待验收。

## Android 与 iOS

**当前暂停原生构建，不作为Web开发和验收的前置条件。** 以下命令供恢复原生任务时参考；先重新评估磁盘、模板Gradle内存配置、Java和SDK环境。2026-10-16构建因磁盘不足失败，未生成APK；按用户要求清理了本轮新增下载及中间产物，未成功验证的Gradle调优也已撤回。详情见[构建与清理记录](2026-10-16-android-build-verification.md)。

```sh
cd apps/client
flutter devices
flutter run -d <设备ID> --dart-define=API_BASE_URL=http://10.0.2.2:8000
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

`10.0.2.2` 是 Android 模拟器访问开发主机的地址。已连接真机可使用 `adb reverse tcp:8000 tcp:8000`，并把 API 参数改为 `http://127.0.0.1:8000`。不要把开发数据库暴露到局域网。只有 Android debug 允许 HTTP，发布应显式配置 HTTPS API。当前模板的 release 签名仍为调试签名，不能作为正式分发包。

恢复任务后，面向arm64手机的本地调试包可使用：

```sh
flutter build apk --debug --target-platform android-arm64 --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

成功后的文件应位于 `apps/client/build/app/outputs/flutter-apk/app-debug.apk`，被Git忽略；目前没有该产物。这个API地址需要手机连接开发主机并执行上述`adb reverse`才可使用；将APK单独发给朋友不能连接这里的服务。构建成功后还需检查APK元数据、签名，再单独完成真机安装、登录与安全存储验收。

2026-10-16 本机 SDK 未接受的协议是 `microxr-sysimage-license`，普通 Android 手机构建没有请求它。不要把 `flutter doctor` 的汇总警告当成当前构建的实际失败阶段；如构建明确请求新组件的许可，由本人阅读并处理。

iOS 使用相同 Flutter 页面与 Keychain 存储；HTTP 开发地址受系统 ATS 限制，使用 HTTPS 开发服务。证书、签名、模拟器和 Keychain 真机验证留在 iOS 验收步骤处理。

## 检查与组件预览

```sh
cd services/api
uv sync --locked --all-extras
uv run pytest -q
uv run ruff check .
uv run ruff format --check .
uv run alembic check
```

```sh
cd apps/client
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
node --test test/web/*_test.mjs
flutter widget-preview start
```

Web字体完整性校验在仓库根目录运行`uv run scripts/check_web_fonts.py`；发布构建后用`uv run scripts/check_web_fonts.py --web-build apps/client/build/web`同时核验发布文件。此工具使用Python3.11/3.12和脚本声明的固定字体依赖，后端仍使用Python3.13。

Web偏好页的“麦克风检查”只在用户点击后申请音频，展示本机短时输入音量，最长30秒，不录音、不上传、不调用模型。取消/超时后的晚到授权也会释放，后台/退出/账号组件更换会停止；回前台需重新开始。真实麦克风、系统许可和手机浏览器仍待人工验收，不能用替身测试充当硬件证据。详见[本机检查验证](2026-10-17-microphone-check-verification.md)。

WebRTC生产传输底层与Dart桥接已实现，尚未接到练习页或供应商。Node检查包含Dart→JS桥接编译；`test/web/realtime_loopback.html`可在独立本地开发服务中执行真实WebRTC回环，输入为合成静音，不申请物理麦克风、不调用模型。它不进入发布包，不作为真实语音或费用验收。步骤与边界见[传输层验证](2026-10-17-web-realtime-transport-verification.md)。

`lib/features/practice/`提供真实HTTP仓库和准备生命周期，按账号绑定原始幂等键、单调代次及业务续租，并可只读读取当前登记；后台/停止仅安全取消未开始信令的登记，失败需明确恢复，不自动重连。provider目前尚未被练习页面消费，创建作用域不自动请求API或麦克风；后端真实准入仍固定503。`flutter test test/features/practice`验证HTTP/时钟替身成功路径，不能作为真实模型或硬件证据。契约与限制见[客户端准备生命周期](../architecture/2026-10-17-client-preparation-lifecycle.md)、[准备验证](2026-10-17-client-preparation-verification.md)与[恢复清理验证](2026-10-17-preparation-recovery-verification.md)。

`lib/features/realtime/api_realtime_signaller.dart`提供账号绑定的独立HTTP单次交换，取消/12秒总等待只关闭自己的客户端，不关闭共享账号API。服务端受限offer路由先持久unknown意图再调用网关，实际网关仍关闭。该适配现由独立PracticeMediaController组合；原准备控制器继续只管理信令前准备。媒体控制器管理配置等待、续租、后台/账号停止和本地释放，信令后不发送准备取消。provider读取不申请媒体，协议工厂默认Unavailable，尚无页面消费；成功配置/媒体路径只使用替身。详见[信令契约](../architecture/2026-10-17-guarded-signalling-api.md)、[媒体协调契约](../architecture/2026-10-17-practice-media-coordinator.md)与[验证](2026-10-17-practice-media-coordinator-verification.md)。

`connection_observation_journal.dart`现接到媒体控制器，按账号/原连接/客户端/epoch记录受限client_observed事实。64条内存队列、16条串行批次、稳定事件身份及独立HTTP的8秒总截止；失败暂停，明确retryPending复用原事件，不写浏览器存储。停止先释放再尽力提交关闭事实，上报失败不影响媒体。API同连接路径的POST/GET observations支持追加及只读分页，8KiB/5秒接收、每连接256条；历史/unknown事实不改状态或终止。真实准入关闭时不会创建journal或测试数据。契约与证据见[观测说明](../architecture/2026-10-18-connection-observations-api.md)及[验证](2026-10-18-connection-observations-verification.md)。

2026-10-18偏好页新增“未结束练习”：点击才GET current，再明确查看连接记录；按原连接身份分页，每页32条。刷新清空旧快照，失败原游标重试；独立HTTP的8秒总截止、账号变化/401清空和作用域销毁保护迟到结果。只读入口不创建、续租、取消、重连或开麦，unknown与客户端本地关闭记录分别显示；没有记录时显示真实空状态。无原创建key或未提交事件的跨进程恢复。详见[只读恢复契约](../architecture/2026-10-18-readonly-recovery-client.md)与[验证](2026-10-18-readonly-recovery-verification.md)。

恢复面板另有明确确认后的未开始准备清理：POST discard-preparation绑定原id/epoch，后端锁后重查完整历史，unknown或历史信令拒绝；前端成功/拒绝/结果未确认分别显示，不自动重放。账号HTTP家族共享CSRF缓存，独立操作不再轮换Cookie破坏首次退出。默认准入仍关闭；本批非空真实浏览器验收只用独立simontalk_test和测试准入，无供应商调用、无开发库种子。详见[契约](../architecture/2026-10-18-preparation-discard-api.md)与[验证](2026-10-18-preparation-discard-verification.md)。

后续已用独立测试库真实浏览器补验断连、真实提交后延迟响应、双标签账号切换与共享会话退出；没有发现确定业务缺陷，未修改生产代码。受控手工步骤、脱敏请求记录和截图见[失败/身份验收](2026-10-18-recovery-browser-failures-verification.md)。临时故障/测试准入不属于默认开发API，不能在实际库照搬测试种子或故障注入。

组件预览位于 `lib/design/account_components.dart`，只展示品牌和按钮的深浅色，不连接服务、不申请媒体权限。品牌启动图标可以用 `uv run --with pillow scripts/generate_brand_icons.py` 重新生成，脚本与 Flutter 的绘制路径保持一致。

另有标题/错误及麦克风失败/等待的浅深色320宽、200%字号预览。2026-10-17默认Previewer实际发现6项，修复独立入口的包资产字体初始化后，卡片与外层标题中文均实际可见；此前空注册问题本轮未复现，不推定其根因。可运行`flutter widget-preview start --web-server --offline`并访问终端地址。连续更新时SDK热重载可能报错，字体缓存变化或报错后采用全局热重启/冷启动。未修改SDK或提交生成目录；证据与限制见[预览字体验证](2026-10-17-preview-font-verification.md)。

GitHub Actions配置了独立PostgreSQL、API检查和Flutter分析/测试/Web构建。按当前Web优先方向，已移除APK自动构建步骤。未推送之前，只能声称工作流已配置，不能声称远端CI已通过。
