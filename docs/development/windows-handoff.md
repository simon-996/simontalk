# Windows 接手续开发

当前目标为 Flutter Web。用 Git for Windows、PowerShell、Flutter 3.47.5 / Dart 3.13.4、Python 3.13、uv、Node.js 和 Chrome。PostgreSQL 17 使用仓库的 Docker Compose 配置，Windows 上可用 Docker Desktop 的 WSL 2 后端。安装后用 `flutter devices` 确认 Chrome 已被识别。[Flutter Web 环境](https://docs.flutter.dev/platform-integration/web/setup) · [Docker Desktop WSL 2](https://docs.docker.com/desktop/features/wsl/) · [uv 管理 Python](https://docs.astral.sh/uv/guides/install-python/)

## 克隆接续分支

在 Windows PowerShell 中打开准备存放项目的目录：

```powershell
git clone --config core.autocrlf=false --branch codex/windows-handoff https://github.com/simon-996/simontalk.git
Set-Location simontalk
git status --short --branch
```

`codex/windows-handoff` 包含截至 2026-11-26 的本地开发进度。用 Codex 打开 `simontalk` 目录，先读根目录 [AGENTS.md](../../AGENTS.md) 和 [HANDOFF.md](../../HANDOFF.md)。

## 启动本地服务

在仓库根目录打开第一个 PowerShell，先启动 Docker Desktop，再运行：

```powershell
docker compose -f deploy/compose.yaml up -d --wait db
docker compose -f deploy/compose.yaml exec -T db pg_isready -U simontalk -d simontalk
docker compose -f deploy/compose.yaml exec -T db createdb -U simontalk simontalk_test

Set-Location services/api
uv python install 3.13
uv sync --locked --all-extras --python 3.13
if (-not (Test-Path -LiteralPath .env)) { Copy-Item .env.example .env }
uv run --locked alembic upgrade head
uv run --locked alembic current
uv run --locked uvicorn simontalk_api.main:create_app --factory --host 127.0.0.1 --port 8000
```

`createdb` 只在第一次创建测试库时执行。交接版本的迁移头为 `19d7a3ec0b51`。开发库和测试库独立，测试会清空指定 `_test` 库的应用表。

另开一个 PowerShell，从仓库根目录运行：

```powershell
Invoke-RestMethod http://127.0.0.1:8000/health/ready
Set-Location apps/client
flutter pub get --enforce-lockfile
flutter run -d chrome --web-hostname 127.0.0.1 --web-port 7357 --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

Web 入口是 `http://127.0.0.1:7357`。浏览器、Web 与 API 使用同一主机名。新开发库需要登录账号时，从 `services/api` 运行 `uv run --locked simontalk-admin invite` 签发开发邀请，再在 Web 注册。

## 首轮回归

客户端终端在 `apps/client` 运行：

```powershell
flutter analyze --no-pub
flutter test --no-pub
$nodeTests = (Get-ChildItem -Path test/web -Filter '*_test.mjs' -File).FullName
node --test $nodeTests
```

后端终端在 `services/api` 运行：

```powershell
uv run --locked alembic check
uv run --locked pytest -q tests/test_qwen_websocket_session.py tests/test_qwen_websocket_turn_policy.py
```

正式通话页隔离联测使用编译后的 Flutter 页面、Chrome 虚拟麦克风、独立测试库以及千问替身。先在 `apps/client` 构建并设置路径，再在同一个 PowerShell 运行测试：

```powershell
flutter build web --release --no-pub --no-web-resources-cdn -t test/web/practice_session_browser_entry.dart -o build/practice-session-handoff
$env:SIMONTALK_FLUTTER_SESSION_BUILD = (Resolve-Path build/practice-session-handoff).Path
$env:SIMONTALK_TEST_BROWSER = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$env:SIMONTALK_TEST_DATABASE_URL = 'postgresql+psycopg://simontalk:simontalk@127.0.0.1:54329/simontalk_test'
Set-Location ../../services/api
uv run --locked pytest -q tests/test_flutter_practice_session_media.py
```

Chrome 安装路径以新电脑的实际位置为准。备份模块依赖 POSIX 文件权限和进程控制，相关备份与恢复验收在 WSL Linux 文件系统或 Linux CI 中运行。[备份契约](../architecture/2026-10-25-backup-bundle.md)

## 接续开发

新开发环境按 `.env.example` 初始化，默认语音准入、千问文本复盘及主动求助关闭。需要做经授权的真实千问试验时，在新电脑上独立配置私有 Key 和北京工作空间，沿用交接文档中的预算和受控试验边界。开发账号、浏览器登录、数据库内容和私有 `.env` 需单独处理。

先用偏好页的本机麦克风检查确认 Windows 和 Chrome 能采集；该检查不调用模型。接着按 [HANDOFF.md 第 4 节](../../HANDOFF.md#4-下一步) 验证实际麦克风、扬声器、首声、回声和停播。插话后续聊、可信上游退出与账单仍待独立验收。[设备中断验证](2026-11-26-browser-media-device-interruption.md)
