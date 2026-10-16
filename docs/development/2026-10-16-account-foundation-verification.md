# 账号与偏好首批验证

日期：2026-10-16（Asia/Shanghai）。范围是工程底座的账号与偏好切片，不能视为阶段2整体完成或实时语音已可用。

## 已交付

- Flutter Android/iOS/Web 工程；Riverpod会话、go_router导航、平台HTTP及凭证适配。
- 邀请注册、登录、一次性凭证重设、明确选择初始难度、个人偏好保存、冲突处理、退出与断网恢复。
- FastAPI、真实PostgreSQL17、首个Alembic迁移、Argon2id、会话摘要及撤销；邀请/偏好/重设事务并发保护。
- Web HttpOnly Cookie、精确Origin、CSRF、账号绑定；移动Bearer安全存储；有界持久限流和脱敏错误。
- 深浅色、响应式、大字号、双弧线品牌及启动图标；Web本地CanvasKit、Noto Sans SC/Roboto与随包字体许可证。
- 本地Compose、运行文档、锁文件、维护CLI和GitHub Actions配置。

## 实际检查

| 检查 | 结果 |
| --- | --- |
| `uv run pytest -q` | **42 passed**，真实PostgreSQL17独立`simontalk_test`，没有SQLite替代 |
| `uv run ruff check .` | 通过 |
| `uv run ruff format --check .` | 20个Python文件符合格式 |
| `uv run alembic check` | 无新增迁移差异；开发库已执行`alembic upgrade head` |
| `uv sync --locked --all-extras` | 锁文件可用 |
| `flutter test` | **21 passed**，网络仓储、真实页面流程、主题与约束测试；使用明确的HTTP替身，不冒充设备测试 |
| `flutter analyze` | 无问题 |
| `dart format --output=none --set-exit-if-changed lib test` | 通过 |
| `flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000` | 通过，Wasm dry run亦通过；正式Wasm运行未验收 |
| `plutil -lint` | iOS项目与Keychain entitlement语法通过，不代表签名/构建/设备通过 |
| `/health/ready` | 本地实际数据库200；断连503由真实连接失败测试覆盖 |

关键覆盖：邀请仅用一次/并发竞争、密码错误与到期/撤销/禁用、用户隔离、偏好原子版本、密码重设撤销全部会话、Cookie不返回Bearer、CSRF/Origin、限流跨实例/容量/清理、错误输入不回显凭证、准备探针失败。

Flutter覆盖：Web不写Bearer、移动凭证传递、401清理、断网保留凭证、请求头等待超时、移动/浏览器退出失败的不同事实、登录后设置未载入的恢复、重复提交、明确难度、保存冲突、换账号草稿清理、320/600/1440宽与约200%字号、320深色设置页与语义前景色。

## 本地浏览器联调

使用仅供本项目联调的账号和开发数据；不是用户学习历史。Web为`127.0.0.1:7357`，API为`127.0.0.1:8000`。

已实际走通邀请码注册、初始难度、修改语速/字幕、保存、刷新恢复与退出确认。刷新后可见语速开启、字幕关闭、中文提示开启，保存按钮禁用，证明恢复了服务器保存值。最终release构建在Edge（Chromium）完成登录→退出→无需刷新再次登录→恢复保存值→再次退出，离开时停在空白登录表单。

应用内浏览器在较早release联调期间出现过“OPTIONS 200、对应POST未到服务端”的连接中断，刷新后可恢复；后续debug构建的连续退出/登录通过，没有把它归因为CSRF或Cookie业务错误，也没有自动重放写操作。临时传输诊断已移除。最终Edge release链路通过，但应用内浏览器该传输现象的根因仍未确定，属于后续环境复核项。

390×844实际浏览器检查了深色偏好页及滚动后的辅助区。新标签加载最终字体方案时，浏览器捕获的error/warn列表为空。没有做断网条件下的完整资源抓包，也没有声称已通过大陆网络性能测试。

截图：[偏好页](screenshots/account-mobile-dark.jpg)、[已保存辅助选项](screenshots/account-options-mobile-dark.jpg)、[最终release登录页](screenshots/login-desktop-release.jpg)。

## 审查与修复

先进行后端规格审查，再对前后端/平台/CI进行独立代码质量审查。修复开发Origin过宽、预检错误未统一JSON两项边界。

质量审查发现一项P2：Web多标签切换账号后，旧标签可能把草稿保存到新账号或退出新账号。已增加`X-Account-ID`绑定、`409 account_changed`、重识别且不重放操作、按用户ID和版本重置草稿；真实PG回归先以200错误失败，修复后通过；Flutter回归检查仅一次PATCH、显示新身份及清空旧草稿。审查者只读复核修复后未发现新增P1/P2；没有进行真实浏览器多标签切号测试。

视觉复查另发现深色难度标题继承黑色，已显式设置语义前景并加入先失败后通过的主题回归；最终手机截图确认文字可读。

## 未验证及环境限制

- **Android APK未构建，原生未安装。** 部分SDK许可未接受，无已连接设备；Gradle9.3.1不在缓存，磁盘可用空间波动至不足1GiB。没有代为接受许可、升级SDK、下载模拟器或删除用户缓存。
- **iOS未构建。** Xcode已安装但doctor无法列出可用Simulator runtime；签名、Keychain与真机待验收。
- CI仅配置，未推送、未在GitHub执行；不能称远端检查通过。
- Flutter组件Preview入口已添加，未启动独立Previewer验收。屏幕阅读器、最大系统字号、实体键盘与真实软键盘、发布签名、大陆首屏性能仍待验证。
- API生产网络、TLS、代理信任、监控、备份恢复、凭证/过期记录长期维护尚未完成。本地开发默认密码不能用于生产。
- 没有调用模型或产生模型费用；实时语音、打断、反馈、重练、历史、用量及费用终止能力均未实现。

## 可复现入口与Git

见[本地开发](local-development.md)和[API说明](../../services/api/README.md)。初次需要单独建立`simontalk_test`，测试只清该库应用表。dev库联调数据保留在专用Compose volume，不在Git中。

main文档基线为`71ecbe0`，本批位于`feat/account-foundation`，完成后保存本地提交；没有推送、PR或对外部署。交接状态见[HANDOFF](../../HANDOFF.md)。
