# Account Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 交付真实 PostgreSQL 账号与偏好 API，以及 Android/Web 优先的 Flutter 注册、登录、初始难度和设置客户端。

**Architecture:** 一个 Flutter 客户端、一个 FastAPI 服务和 PostgreSQL。前后端遵循固定账号契约，UI 不持有供应商密钥；Cookie/Bearer 通过平台适配分开。

**Tech Stack:** Flutter 3.47.5、Riverpod、go_router、http、flutter_secure_storage；Python 3.13、uv、FastAPI、SQLAlchemy、psycopg、Alembic、PostgreSQL 17。

先读 [工程决策](../../architecture/2026-10-15-foundation-decisions.md) 与 [接口契约](../../architecture/2026-10-15-account-api.md)。此计划只覆盖账号与设置，不执行付费模型调用。

## 文件职责

- services/api/pyproject.toml、uv.lock：后端依赖与复现；src/simontalk_api/ 内按配置、数据库、实体、身份、接口和 CLI 拆分。
- services/api/alembic/ 与 alembic.ini：可重复执行的首个数据库迁移。
- services/api/tests/：真实 PostgreSQL 下的身份、邀请、隔离、版本、Cookie/CSRF 和错误测试。
- apps/client/：Flutter Android/iOS/Web 工程；lib/core/ 为网络/凭证，lib/design/ 为主题/品牌/共享组件，lib/features/account/ 为模型、仓储、状态与表单；test/ 为行为与布局验证。
- deploy/compose.yaml：仅绑定本机的独立开发 PostgreSQL；.github/workflows/checks.yml：静态分析、测试与构建。
- docs/development/：启动、迁移、维护 CLI 和实际验收记录；HANDOFF.md 更新真实进度。

## Task 1：建立本地基线和开发环境

- [x] 验证现有文档链接，保存为 main 的本地初始提交，切换 feat/account-foundation；保留当前目录，未经要求不推送。
- [x] 添加忽略规则：环境文件、.venv、.dart_tool、build、Python 缓存、签名文件；保留锁文件和 .env.example。
- [x] 创建独立 PostgreSQL 服务，绑定 127.0.0.1:54329，数据库 simontalk；测试使用独立 simontalk_test 数据库，不删除其他项目的数据。

```sh
docker compose -f deploy/compose.yaml up -d db
docker compose -f deploy/compose.yaml exec -T db pg_isready -U simontalk
```

预期数据库健康；若下载或存储失败，记录原因并继续可独立完成的工作，不清理用户缓存。

## Task 2：后端身份与偏好

- [x] 先建立测试，确认尚未实现时失败；再按契约实现注册、登录、退出、密码重设、GET me 和偏好读写。
- [x] PostgreSQL 实体包含 User、Invite、AuthSession、PasswordResetGrant、UserPreferences 和有界限流记录；摘要存储高熵 token，Argon2id 保存密码。
- [x] 事务验证单次邀请和重设凭证，登录撤销与禁用即时生效；PATCH version 原子比较更新。
- [x] 处理非法输入、Cookie/CSRF/Origin、生产 Secure 配置、凭证脱敏和统一错误；禁止把用户名碰撞或密码差异暴露成登录枚举。
- [x] 添加迁移与维护 CLI，先迁移再运行服务，禁止启动时悄悄 create_all 代替迁移。

```sh
cd services/api
uv sync --all-extras
uv run alembic upgrade head
uv run pytest -q
uv run ruff check .
```

测试至少覆盖：一次邀请成功和重复失败、错误密码、到期/撤销会话、两用户隔离、版本冲突、重设后旧会话无效、Web 不返回 bearer、缺 CSRF/恶意 Origin 拒绝、限流、ready 数据库失败。使用真实数据库，不以 SQLite 通过冒充 PostgreSQL 验证。

## Task 3：Flutter 工程与平台网络

- [x] 使用 flutter create 生成 Android/iOS/Web 平台工程，删除生成的计数器演示，加入已核对的依赖并保存 pubspec.lock。
- [x] 先写仓储测试：凭证传递、401、网络失败、注册响应、偏好序列化与冲突；验证失败后实现。
- [x] 实现 http Client 平台工厂、Web withCredentials、移动安全存储、CSRF 获取与请求头；API_BASE_URL 是公开端点配置，不承载密钥。
- [x] 使用 Riverpod 管理会话与加载状态，go_router 管理登录/加入/重设/初始设置/个人偏好路径。网络失败有重试，不能当成已退出。

```sh
cd apps/client
flutter pub get
flutter test
flutter analyze
```

## Task 4：真实表单与主题

- [x] 按视觉规范创建深浅色主题、48 以上命中区、字号与留白；组件职责分开，媒体功能不混入账号页面。
- [x] 实现邀请码注册、登录、维护者重设凭证入口；第一次登录明确选择难度；个人页编辑难度、语速、字幕、中文提示并真实保存，提供退出。
- [x] 测试提交等待、字段错误、网络重试、保存冲突、深浅色、320 宽和约 200% 文字缩放，确认溢出和焦点问题。
- [x] 不添加不可用的假聊天按钮、虚构练习、假统计或假成绩。

```sh
cd apps/client
flutter test
flutter build web --release
flutter build apk --debug
```

不自动接受 Android 许可证或下载模拟器镜像；原生构建受许可、设备或磁盘限制时记录原始结果，不声称三端验收通过。

## Task 5：集成、复核与交接

- [x] 本地启动 API 与 Flutter Web，使用本地测试邀请完成注册、难度设置、偏好修改、刷新、退出与重新登录；测试数据不作为真实学习记录。
- [x] 先进行规格符合性复核，再进行代码质量复核；修复实际问题并重复受影响的检查。
- [x] CI 使用独立 PostgreSQL 服务、uv、Flutter 和已提交锁文件；不需要生产密钥，不执行付费调用。
- [x] 更新 README 启动方法、运行文档、实际验证记录及 HANDOFF。区分已通过、未运行和受环境限制的结果，提交本地功能分支，保留未推送状态。

完成依据：账号与偏好链路真实可用，关键后端测试与 Flutter 分析/测试通过，Web 构建可交付；Android 构建结果如实记录。阶段 2 的其他范围仍按建设路线后续推进，不提前标记整体完成。

## 执行结果（2026-10-16）

本批账号/偏好实现与本地自动检查、Web联调已完成，证据见[验证记录](../../development/2026-10-16-account-foundation-verification.md)。上方勾选表示对应实现或检查已执行，不代表三端全面验收。Android APK/iOS构建、真机、远端CI与Previewer未运行；应用内浏览器传输现象仍待环境复核。阶段2其余门槛继续按路线推进，未推送或部署。
