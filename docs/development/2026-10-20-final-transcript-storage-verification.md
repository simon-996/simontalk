# 最终文字持久提交验证（2026-10-20）

## 本次交付

实现[最终文字契约](../architecture/2026-10-20-final-transcript-storage.md)：最终用户话语/AI生成文本的原连接追加修订、精确确认、分页读取及Flutter内存确认队列，默认账号媒体provider已装配。媒体仅提交受保护投影实际applied的final TranscriptUpdate。AI持久读取明确unknown播放状态，未实现服务端固化、播放证据持久化或反馈。

实施遵循[计划](../superpowers/plans/2026-10-20-final-transcript-storage.md)。测试先于实现：新POST原来404，新增body限制原来未拦截；客户端journal、媒体和provider端口最初缺失，revision_stale错误码最初归入通用失败。相关RED记录在本机`/tmp/simontalk-transcript-red.log`、`simontalk-final-transcript-client-red.log`、`simontalk-final-transcript-provider-red.log`、`simontalk-final-transcript-code-red.log`。

## 自动检查

| 检查 | 实际结果 |
| --- | --- |
| 原观测基线 | 25项通过，3.96秒 |
| 后端完整pytest | **276项通过**，47.88秒，独立simontalk_test；比上批225新增51项 |
| Flutter完整测试 | **311项通过**，约11秒；比上批282新增29项 |
| 最后样式修正后受影响队列/媒体 | 29项通过 |
| Flutter analyze | 无问题，9.6秒 |
| Dart格式 | 78文件，0更改 |
| Node | **51项通过**，约0.62秒，包含实际Dart→JS桥接编译 |
| Ruff | check通过，format检查51文件通过 |
| Alembic | 独立测试库b97d2a641e30→f80e9c1a24bd→b97d2a641e30降/升验证；修复模型后check无新增操作，完整pytest含模型与迁移一致性回归 |
| Web release | **32.1秒通过**，回环API，no-web-resources-cdn；Wasm dry run通过，不等于实际Wasm发布/设备验收 |
| 发布字体 | 30,890 Unicode映射完整，WOFF2 7,782,072字节，构建包含压缩中文和本地Roboto |
| 开发库 | 升级b97d2a641e30，check通过；升级前后1账号、0练习/连接/观测，新文字0；默认API /health/ready 200 |

覆盖：精确重放/完整原子批次、历史修订/索引与语义版本缺口、旧页后追加修订、并发冲突、512修订/256turn/1MiB各边界及满额重放、UTF-8字节/最大JSON转义、非法Unicode/NUL/额外字段脱敏、数据库身份/行约束/级联、删除后迟到404、账号锁等待中撤销、Web Origin/CSRF/账号绑定、body超限/超时。客户端覆盖4条串行批次、错误ACK身份/ID/水位/预算、相同事件重试、CSRF/POST8秒截止、迟到ACK、finish/abort/账号变化、容量缺口及媒体/默认provider接入。

初次检查抓到并修复两类问题：

- 新模型插入位置使原观测约束误归到文字类。独立审查与Alembic check均确认；先补compare_metadata失败回归，再将原约束移回原类。数据库迁移定义本身正确；最终check和完整测试通过。
- 初次静态分析有null-aware map及测试if括号两条风格提示；已修复，受影响29项与分析/格式复验通过，无行为变化。

初次非法Unicode测试由HTTPX在发送前拒绝，随后改发ASCII转义原始JSON，验证服务端422而非客户端编码异常。本机开始时Docker未启动、SDK/工具PATH及缓存权限受限；启动既有项目容器、使用既有虚拟环境/SDK/绑定Node绝对路径并在授权范围运行后验证。最初Node桥接失败因子进程找不到dart，补齐PATH后51项全过，无传输源代码更改。

## 实际HTTP与PostgreSQL连通

本机临时8001 API使用**独立测试库及注入测试准入**，供应商网关继续Unavailable。通过Flutter测试运行实际Dart ApiClient+FinalTranscriptJournal、Bearer身份和网络HTTP访问API；不是MockClient，也不是浏览器Cookie/真实媒体验收。

先提交两条最终文字，客户端故障注入在收到真实成功HTTP响应后读完并丢弃响应，向journal抛网络错误。此时断言pending=2、error=network_error，实际GET已见数据库2条。明确retry后pending=0/error=null，GET仍2条；再提交原用户话语revision2，GET after_sequence=2得到原turn的新版本，总数3。AI读取delivery_status=unknown，提交前后连接status/termination/lease一致；finish后不新增事件。跨进程验收1项通过，日志`/tmp/simontalk-final-transcript-wire.log`；脱敏[证据JSON](evidence/2026-10-20-final-transcript-wire.json)不含正文/凭证。

验收期间准备租约后来由既有测试maintenance过期，清理时状态failed/not_started；不与提交时“未改变状态”的断言混淆。停止临时API后清理仅本轮测试账号/邀请码及级联练习/连接/文字。首次清理因用户仍被已消费邀请码引用而整体回滚，改为先删该邀请码后删账号成功；未写开发库假练习。开发API8000随后使用默认关闭准入/网关启动，保留供本地开发。

## 审查与剩余边界

后端独立审查发现模型约束问题并在修复后复查；客户端独立审查完成，均未发现剩余确定缺陷。审查为静态只读，不计作自动测试证据。

本批没有UI变化，未新跑浏览器/组件预览，不声称跨标签Cookie或实际供应商语音已接通。文字来源始终client_reported；当前仅final修订，AI播放持久证据、服务端封存、结束/反馈任务、账号作用域的客户端分页读取仓库及历史UI、移动保护outbox、跨进程未确认队列恢复仍未实现。Web内存待确认内容刷新会丢失；rejectedCount/error保留容量缺口。实际模型/预算/设备任务继续暂缓；未推送/部署/构建原生。
