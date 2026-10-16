# 本地开发

当前真实可用范围是账号与练习偏好。语音、反馈、记录及费用尚未接入。2026-10-16用户更新为 **Flutter Web优先**；Android构建与安装验收暂停，保留Android/iOS工程。

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
```

邀请单次 72 小时；重设凭证单次 15 分钟。凭证仅显示一次，不写入 Git。前台不自动发短信、邮件，也不提供远程管理员 API。更多身份与生产配置见 [API 说明](../../services/api/README.md)。

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

Web首帧前有HTML加载状态，15秒后允许继续等待或主动重载，启动资源或初始化失败有重载入口。首帧后由Flutter接管；这些状态不等于已支持离线使用。中文字体当前约17.8MB，加载优化与真实网络基线仍待完成，见[Web验证记录](2026-10-16-web-foundation-verification.md)。

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
node --test test/web/startup_test.mjs
flutter widget-preview start
```

组件预览位于 `lib/design/account_components.dart`，只展示品牌和按钮的深浅色，不连接服务、不申请媒体权限。品牌启动图标可以用 `uv run --with pillow scripts/generate_brand_icons.py` 重新生成，脚本与 Flutter 的绘制路径保持一致。

另有标题/错误的浅深色320宽、200%字号预览定义。2026-10-16实际运行Previewer时，Web服务可启动但显示“No previews detected”；没有把它视为预览验收成功。详细现象见Web验证记录，未修改SDK或把临时生成目录提交到Git。独立预览工具尚待排查，页面可继续通过widget测试和正式Web产物验证。

GitHub Actions配置了独立PostgreSQL、API检查和Flutter分析/测试/Web构建。按当前Web优先方向，已移除APK自动构建步骤。未推送之前，只能声称工作流已配置，不能声称远端CI已通过。
