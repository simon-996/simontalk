# SimonTalk API

Python 3.13+、uv、FastAPI、同步 SQLAlchemy/psycopg 与 PostgreSQL 17。账号与个人偏好使用真实数据库，服务启动不自动创建表；必须先执行 Alembic 迁移。

另有供应商无关的练习准备登记：所有权、偏好快照、UUID幂等键和单用户并发保护。真实语音准入固定关闭，创建返回503 `realtime_unavailable`且不写练习；没有环境开关能启用空服务，也没有供应商调用。成功路径只通过独立测试库中的明确策略替身验证。接口与未来媒体边界见[准备登记契约](../../docs/architecture/2026-10-17-practice-preparation-api.md)。

连接准备登记、单调代次与45秒业务租约也已实现，沿用同一关闭准入。只有确定未开始上游的准备可安全取消或到期终结；上游未知继续占用，不能依赖本地停止或租约推断费用终止。详见[连接契约](../../docs/architecture/2026-10-17-connection-reservations-api.md)。

另有`GET /v1/practice-sessions/current`按本人身份只读恢复当前登记；API正常lifespan每15秒自动执行一批连接租约及300秒闲置准备清理，未知/历史上游继续保留。详见[恢复与清理契约](../../docs/architecture/2026-10-17-preparation-recovery-and-cleanup.md)。

## 本地启动

从仓库根目录启动专用开发数据库：

```sh
docker compose -f deploy/compose.yaml up -d db
cd services/api
uv sync --all-extras
cp .env.example .env
uv run alembic upgrade head
uv run uvicorn simontalk_api.main:create_app --factory --host 127.0.0.1 --port 8000
```

`GET /health/live` 不依赖数据库，`GET /health/ready` 执行真实数据库查询；数据库不可用返回脱敏的 503。数据库开发地址仅供本机使用；`.env` 不应提交。

Web 开发固定端口 7357。Web 与 API 使用相同主机名（都用 `127.0.0.1` 或都用 `localhost`），端口可不同，保持 `SameSite=Lax` Cookie 正常发送。移动端发送 `Authorization: Bearer …`，Android 模拟器连接 `10.0.2.2:8000` 时需由维护者按需把 API 绑定到可访问的开发接口。

## 维护 CLI

```sh
uv run simontalk-admin invite
uv run simontalk-admin reset alice
uv run simontalk-admin disable alice
uv run simontalk-admin expire-connections --limit 100
uv run simontalk-admin cleanup-preparations --limit 100
```

CLI 依赖本地数据库环境权限，不提供远程管理员 API。邀请和重设命令在事务提交后只打印一次凭证，请通过用户已授权的渠道交给本人；数据库仅保存 SHA-256 摘要。邀请单次有效 72 小时，重设单次有效 15 分钟；重设成功立即撤销该用户全部登录会话与其他重设凭证。禁用账号立即阻止身份查询与登录。

`expire-connections`只扫描单批到期业务租约；`cleanup-preparations`执行和后台相同的完整批次。limit为1–1000，跳过持锁对象并在锁后重查，提交后只打印数量；上游未知不释放占用，也不会断开供应商媒体。自动任务需API lifespan启用，进程停止期间不执行；readiness目前只验证数据库。

## 身份与错误

- 用户名小写，3–32 个 ASCII 字母、数字、下划线，首位字母；密码 12–128 字符，以 Argon2id 保存。会话固定 7 天。
- Web 先请求 `/v1/auth/csrf`，携带 Cookie 和 `X-CSRF-Token` 提交状态改变请求。Web 注册/登录传 `platform: web`，仅收到 HttpOnly Cookie；移动端传 `platform: mobile` 并接收 `access_token`。
- 浏览器请求只允许精确配置的 Origin；带浏览器来源的 `platform: mobile` 请求被拒绝，避免向浏览器返回 bearer。Cookie 与 Bearer 凭证类型不可互换。
- 每个响应提供服务端生成的 `X-Request-ID`；错误 JSON 为 `code`、`message`、`request_id`，不回显验证原始输入、密码、令牌或数据库连接细节。无效重设返回 `400 reset_invalid`。
- 偏好 PATCH 必须提供当前 `version`；原子条件更新后版本加一，旧版本返回 `409 preferences_conflict`。只查询当前身份的数据。
- 偏好读取/保存与退出携带 `X-Account-ID` 绑定页面所见身份；Web已认证变更必须携带。身份不匹配返回 `409 account_changed`，防多标签共享Cookie时把旧草稿存到新账号；客户端重新识别，不自动重放。
- 注册、登录、重设和 CSRF 签发使用 PostgreSQL 持久限流。默认窗口 600 秒；登录每 IP 30 次、每账号 10 次；注册/重设每 IP 10 次；CSRF 每 IP 60 次。计数饱和，自动清除过期记录，默认最多 10,000 个摘要键，满容量时拒绝新增键。多服务进程共享数据库计数。

## 配置与生产边界

配置均以 `SIMONTALK_` 开头，支持 `.env`。`SIMONTALK_DATABASE_URL` 必须使用 `postgresql+psycopg://`。`SIMONTALK_ALLOWED_ORIGINS` 使用 JSON 数组，禁止通配符、路径和用户名；开发模式只允许 `localhost` / `127.0.0.1` 来源。`SIMONTALK_ENVIRONMENT=production` 强制 Secure Cookie 并要求来源 HTTPS。生产必须显式设置数据库凭证与允许来源，提供 HTTPS 终止及同站点 Web/API 域名。

`SIMONTALK_PRACTICE_MAINTENANCE_INTERVAL_SECONDS`默认15秒，范围1–300；每进程一条串行线程和独立数据库池，单批事务/SQL/锁等待分别受局部5秒/2秒/100毫秒限制。失败回滚后下轮重试，关闭服务最多等待线程10秒；不要把后台业务清理视为供应商终止或计费控制。

部署反向代理前，限流使用实际 socket IP，不信任未经配置的 `X-Forwarded-For`。生产网络、代理信任链、TLS、备份恢复、监控和真实设备验收仍属于后续部署验证。当前 API 不调用模型、不发送短信或邮件。

## 检查

```sh
uv sync --locked --all-extras
uv run pytest -q
uv run ruff check .
uv run ruff format --check .
uv run alembic check
```

测试默认使用 `simontalk_test`；可通过 `SIMONTALK_TEST_DATABASE_URL` 指定另一独立 PostgreSQL 测试库，名称必须以 `_test` 结尾。夹具先运行迁移，再清空测试库的应用表，绝不使用 SQLite 替代验证。不要把测试地址指向业务库。

首次在仓库根目录执行 `docker compose -f deploy/compose.yaml exec -T db createdb -U simontalk simontalk_test` 建立独立测试库；已存在时跳过。

测试覆盖邀请/偏好/重设的并发原子性、凭证摘要、用户隔离、过期/撤销/禁用、Cookie/CSRF/Origin、生产 Secure、持久限流容量与清理、敏感信息脱敏以及真实数据库断连时的 readiness。

练习/连接准备测试另覆盖同/异幂等键并发、数据库所有权/唯一/证据组合约束、快照不变、跨应用实例重放、持锁期间撤销/禁用、旧代次与客户端、续租/扫描/取消竞争及真实扫描CLI。SDP网关、实际媒体终止、转写和费用尚未实现；取消准备不能用于关闭已建媒体。
