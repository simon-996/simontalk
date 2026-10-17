# 账号与工程基础决策

日期：2026-10-15。依据：现有产品/技术/视觉规格，以及用户“开始吧”“继续”的开发指令。以下是沿用已展示推荐形成的工程采用结论，不冒充用户逐项确认；后续可根据实际验证调整。

## 本次采用

| 项目 | 决定 |
| --- | --- |
| 首批验证 | 2026-10-16用户更新为Flutter Web优先；Android构建与设备验收暂停，保留Android/iOS工程，后续恢复时单独验证 |
| Flutter | 使用本机 stable 3.47.5 / Dart 3.13.4，不为本次开发升级全局 SDK |
| 客户端 | Riverpod、go_router、http；移动端凭证使用 flutter_secure_storage，Web 使用 HttpOnly Cookie |
| Web媒体底层 | 2026-10-17工程采用浏览器原生RTCPeerConnection，经dart:js_interop封装传输接口；不新增原生依赖。模型协议、供应商鉴权与物理设备验收仍待接入，原生恢复时另行评估flutter_webrtc |
| 后端 | Python 3.13、uv、FastAPI、Pydantic、同步 SQLAlchemy、psycopg、Alembic |
| 数据库 | PostgreSQL 17，开发环境使用独立 Docker Compose 服务，端口仅绑定本机 |
| 身份 | 单次邀请码、用户名/密码；随机 opaque session、摘要存储、固定 7 天；密码 Argon2id |
| 恢复 | 管理 CLI 生成 15 分钟单次重设凭证；用户自行设置新密码，撤销全部登录会话 |
| 个人偏好 | 难度初始未选择；用户明确选择基础/进阶/熟练后持久保存；语速、字幕、中文提示和按需翻译独立字段 |
| 视觉 | 采用现有绿色、深浅色及尺寸角色；原生系统字体，Web 打包 Noto Sans SC 与引擎必需 Roboto，避免运行时依赖 Google 字体服务 |
| 工作区 | 按用户指定的当前项目文件夹开发；本地保存文档基线后使用 feat/account-foundation 分支，不执行远端推送 |

## 已核对的环境

- macOS 26.6.2 / Apple Silicon；Flutter 3.47.5、Dart 3.13.4、Python 3.13.0、uv 0.11.8。
- Docker Engine 27.4.0、Compose 2.31.0 可用，尚无 PostgreSQL 镜像。
- Android SDK 36 位于本机已配置的环境目录，平台与构建工具已安装；flutter doctor 报部分许可证未接受，没有已连接的 Android 真机。不自动替用户接受许可。
- Xcode 27.0 已安装，doctor 无法取得 Simulator runtimes 列表；不把 iOS 工程生成当成设备验收。
- Chrome 可用。磁盘可用约 3.9 GiB；不升级 SDK、不下载模拟器镜像、不删除用户缓存或其他项目文件，构建过程中监控空间。

## 交付边界

本批完成可运行的账号与个人偏好，不接入付费模型，不生成虚构练习。API 和 Flutter 必须使用同一份[账号接口契约](2026-10-15-account-api.md)，真实数据库验证、客户端测试和构建结果分别记录。

模型权限、试验预算、具体真机版本和供应商强制终止能力，在对应语音试验前补齐；不阻塞不依赖模型的工程工作。邀请码/重设凭证/登录会话期限沿用技术设计，后续范围、数据及后台策略继续由总纲维护。
