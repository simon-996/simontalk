# 单次信令边界验证

日期：2026-10-17；基线提交991b705。本批在现有功能分支本地实施，没有推送、对外部署、模型调用或原生构建。

## 已实现

- 后端offer路由、96KiB实际分块接收/5秒边界、严格64KiB UTF-8 SDP输入及Web身份保护。
- 提交摘要和negotiating/unknown意图后才释放锁并调用异步网关；每连接至多一次，8秒等待；完成事务重新检查身份、准入、配置、代次、状态和租约，有效答案仅进入configuring。
- 失败/超时/晚到结果保守占用，不把请求取消当作上游终止；实际准入与网关均为Unavailable，没有环境开关开放空服务。
- ApiClient独立派生账号作用域和每请求中止信号；ApiRealtimeSignaller总等待12秒、单次调用、身份/答案校验、立即取消及迟到丢弃，只关闭自己的HTTP客户端。
- Alembic添加摘要/时间及约束，Offer/Answer不写数据库或异常日志；没有答案缓存或自动重放。

## 自动检查

| 检查 | 本批实际结果 |
| --- | --- |
| `uv run pytest -q` | 164 passed，44.13s；原133项加信令24项、接收边界7项 |
| `uv run pytest -q tests/test_signalling.py tests/test_offer_body_limit.py` | 最终定向31 passed，3.81s |
| `uv run ruff check .` / `uv run ruff format --check .` | 通过；41文件格式一致 |
| 开发库/独立测试库`uv run alembic check` | 均No new upgrade operations detected |
| `flutter test --no-pub` | 99 passed，10s；原82项加HTTP信令17项 |
| `flutter analyze --no-pub` | No issues found |
| `dart format --output=none --set-exit-if-changed lib test` | 46文件，0 changed |
| `node --test test/web/*_test.mjs` | 51 passed，包含Dart桥接编译与传输已有回归 |
| Web release，关闭资源CDN、本地API参数 | 修复后最终成功，42.6s |
| `uv run scripts/check_web_fonts.py --web-build apps/client/build/web` | 通过，保留30,890字符映射、本地Roboto和摘要一致的7,782,072字节中文字体 |

外部交换测试用独立事务重新取得User/Practice/Connection全部锁，同时观察已提交的negotiating/unknown及摘要，证明网关调用不占住原事务。覆盖同/异offer、并发、重启、身份撤销/禁用、配置变更、租约到期、扫描抢先、无效/超大答案及SDK异常；数据库不含原SDP标记，错误不泄露替身私密异常。

按先失败再修复，额外重现了两个边界：网关校验后替换app状态会调用未检查实例，现固定原实例；超限响应发送较慢会被接收deadline打断并尝试发送第二个状态，现响应发送移到接收限时之外。相应回归通过。Web专测缺Origin/CSRF/account绑定时不调用网关。

客户端覆盖取消前/中、晚到响应、源账号改变/关闭、CSRF和凭证异步边界、共享API继续可用、响应身份/体积、503不重试及12秒总等待。所有成功信令为明确HTTP/网关替身，不代表真实媒体互通。

独立静态审查发现1个P2：本地http1.6的BrowserClient在响应头返回后移除close所用AbortController，单靠close不能终止仍在读取的响应体。新增CSRF/offer各自取消/超时4项流式响应测试，先全部失败；修复为每请求AbortableRequest中止信号后，信令定向17项和完整客户端99项通过。修复复核确认原问题已覆盖，未发现新增确定P1/P2。审查为只读静态检查，未独立重跑测试。

## 本地运行证据

开发库从c43a7de028f1添加性迁移到e19bd728ca41。迁移前后均1账号、0练习、0连接；没有创建假练习或修改用户身份。独立测试库由测试夹具升级到相同head。

核实原Uvicorn为本项目本地进程后重启，真实HTTP检查：readiness200；有效格式的匿名offer401 unauthorized；96KiB+1请求413 request_too_large。三者均含X-Request-ID/no-store，413保留允许来源的CORS。业务成功/默认503由独立数据库测试验证，没有向开发库注入测试准入。

## 尚未完成

客户端signaller、准备控制器和WebRTC底层尚未组合，没有新增练习页面或申请物理麦克风。供应商端点/凭证、事件协议、配置确认、可信终止、用量和费用仍待实现与实测。异步网关协议要求适配器支持取消，8秒等待不是已验证的供应商行为；取消/进程退出可能留下negotiating/unknown，由租约扫描保守处理。无答案缓存的尝试不能通过重发恢复答案。

下一步先做可独立验证的媒体业务协调器，按代次和账号组合准备、信令、配置确认与媒体释放；不要把现有信令前控制器直接接到媒体。账号/预算、真实设备及物理权限任务按用户指令暂缓。
