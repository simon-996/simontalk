# 本地开发

当前真实可用范围是账号与练习偏好。语音、反馈、记录及费用尚未接入。Android 优先，同时验证 Web；iOS 已有工程配置，尚未构建或真机验收。

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

## Android 与 iOS

```sh
cd apps/client
flutter devices
flutter run -d <设备ID> --dart-define=API_BASE_URL=http://10.0.2.2:8000
flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

`10.0.2.2` 是 Android 模拟器访问开发主机的地址。已连接真机可使用 `adb reverse tcp:8000 tcp:8000`，并把 API 参数改为 `http://127.0.0.1:8000`。不要把开发数据库暴露到局域网。只有 Android debug 允许 HTTP，发布应显式配置 HTTPS API。当前模板的 release 签名仍为调试签名，不能作为正式分发包。

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
flutter widget-preview start
```

组件预览位于 `lib/design/account_components.dart`，只展示品牌和按钮的深浅色，不连接服务、不申请媒体权限。品牌启动图标可以用 `uv run --with pillow scripts/generate_brand_icons.py` 重新生成，脚本与 Flutter 的绘制路径保持一致。

GitHub Actions 配置了独立 PostgreSQL、API 检查和 Flutter 分析/测试/Web 构建。未推送之前，只能声称工作流已配置，不能声称远端 CI 已通过。
