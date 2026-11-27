# 本地开发

项目进度与当前任务见 [HANDOFF.md](../../HANDOFF.md)。本页用于启动标准开发环境。复验同源 WebSocket 语音入口时，使用[单独的浏览器联测说明](2026-11-24-flutter-browser-media-verification.md)和专用测试库。该验证可以使用虚拟麦克风与供应商替身完成。

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

更新后运行`uv run alembic upgrade head`，本次交接迁移头为`19d7a3ec0b51`。语音用量、日常话题、主动求助和逐句翻译接在`4f6a58cd2e32`之后（完整删除成员凭据；`3e5947bc0d21`为本人范围删除，`2d4836ab9c10`为历史seek索引，`1a6de74c9f20`为一级重练来源/冻结目标、同账号ordinary父约束及同级seek部分索引；8b2731f5ca90为持久反馈任务/尝试/动作/结果4表；4c913f2d8e71为复盘输入，0e1874613efa为练习固化/成员快照/blocked核验意图，d41a7c9e2b60为独立播放证据，b97d2a641e30为最终文字修订）。API源码修改后须重启本地Uvicorn，启动命令未启用自动重载。真实运行的新练习/连接准入及信令网关固定关闭；测试策略仅用于独立测试库，不能通过环境变量开启没有接入的语音服务。正常API lifespan现每15秒自动执行一批连接租约、300秒闲置准备清理、已到30秒补交截止的输入固化及缺失blocked核验意图补齐，间隔可由`SIMONTALK_PRACTICE_MAINTENANCE_INTERVAL_SECONDS`设为1–300秒；手动完整批次使用cleanup-preparations。未开始上游可安全终结，上游未知继续占用；进程关闭期间不调度，没有媒体终止能力。详见[准备登记验证](2026-10-17-practice-preparation-verification.md)、[连接租约验证](2026-10-17-connection-reservations-verification.md)、[恢复清理验证](2026-10-17-preparation-recovery-verification.md)、[单次信令验证](2026-10-17-guarded-signalling-verification.md)、[受限观测验证](2026-10-18-connection-observations-verification.md)、[最终文字验证](2026-10-20-final-transcript-storage-verification.md)及[播放证据验证](2026-10-21-playback-evidence-verification.md)。

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

若`flutter test`在加载阶段整批失败并报`Unable to connect to flutter_tester process: WebSocketException`，先检查环境里是否有`HTTP_PROXY`/`HTTPS_PROXY`：代理会劫持`flutter_tester`与本机回环端口的连接。用`env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy flutter test`重跑即可；同理，`pytest`的`tmp_path`在受限沙箱下可能因目录创建失败而整批报错，可加`--basetemp`指定可写临时目录。这两类都属于运行环境问题，不是用例失败，也不要据此改源码。

Web偏好页的“麦克风检查”只在用户点击后申请音频，展示本机短时输入音量，最长30秒，不录音、不上传、不调用模型。取消/超时后的晚到授权也会释放，后台/退出/账号组件更换会停止；回前台需重新开始。真实麦克风、系统许可和手机浏览器仍待人工验收，不能用替身测试充当硬件证据。详见[本机检查验证](2026-10-17-microphone-check-verification.md)。

WebRTC生产传输底层与Dart桥接已实现，尚未接到练习页或供应商。Node检查包含Dart→JS桥接编译；`test/web/realtime_loopback.html`可在独立本地开发服务中执行真实WebRTC回环，输入为合成静音，不申请物理麦克风、不调用模型。它不进入发布包，不作为真实语音或费用验收。步骤与边界见[传输层验证](2026-10-17-web-realtime-transport-verification.md)。

`lib/features/practice/`提供真实HTTP仓库和准备生命周期，按账号绑定原始幂等键、单调代次及业务续租，并可只读读取当前登记；后台/停止仅安全取消未开始信令的登记，失败需明确恢复，不自动重连。provider已由普通首页/准备入口消费，创建作用域不自动请求API或麦克风；后端真实准入仍固定503。`flutter test test/features/practice`验证HTTP/时钟替身成功路径，不能作为真实模型或硬件证据。契约与限制见[客户端准备生命周期](../architecture/2026-10-17-client-preparation-lifecycle.md)、[准备验证](2026-10-17-client-preparation-verification.md)与[恢复清理验证](2026-10-17-preparation-recovery-verification.md)。

`lib/features/realtime/api_realtime_signaller.dart`提供账号绑定的独立HTTP单次交换，取消/12秒总等待只关闭自己的客户端，不关闭共享账号API。服务端受限offer路由先持久unknown意图再调用网关，实际网关仍关闭。该适配现由独立PracticeMediaController组合；原准备控制器继续只管理信令前准备。媒体控制器管理配置等待、续租、后台/账号停止和本地释放，信令后不发送准备取消。provider读取不申请媒体，协议工厂默认Unavailable，尚无页面消费；成功配置/媒体路径只使用替身。详见[信令契约](../architecture/2026-10-17-guarded-signalling-api.md)、[媒体协调契约](../architecture/2026-10-17-practice-media-coordinator.md)与[验证](2026-10-17-practice-media-coordinator-verification.md)。

`connection_observation_journal.dart`现接到媒体控制器，按账号/原连接/客户端/epoch记录受限client_observed事实。64条内存队列、16条串行批次、稳定事件身份及独立HTTP的8秒总截止；失败暂停，明确retryPending复用原事件，不写浏览器存储。停止先释放再尽力提交关闭事实，上报失败不影响媒体。API同连接路径的POST/GET observations支持追加及只读分页，8KiB/5秒接收、每连接256条；历史/unknown事实不改状态或终止。真实准入关闭时不会创建journal或测试数据。契约与证据见[观测说明](../architecture/2026-10-18-connection-observations-api.md)及[验证](2026-10-18-connection-observations-verification.md)。

2026-10-18偏好页新增“未结束练习”：点击才GET current，再明确查看连接记录；按原连接身份分页，每页32条。刷新清空旧快照，失败原游标重试；独立HTTP的8秒总截止、账号变化/401清空和作用域销毁保护迟到结果。只读入口不创建、续租、取消、重连或开麦，unknown与客户端本地关闭记录分别显示；没有记录时显示真实空状态。无原创建key或未提交事件的跨进程恢复。详见[只读恢复契约](../architecture/2026-10-18-readonly-recovery-client.md)与[验证](2026-10-18-readonly-recovery-verification.md)。

恢复面板另有明确确认后的未开始准备清理：POST discard-preparation绑定原id/epoch，后端锁后重查完整历史，unknown或历史信令拒绝；前端成功/拒绝/结果未确认分别显示，不自动重放。账号HTTP家族共享CSRF缓存，独立操作不再轮换Cookie破坏首次退出。默认准入仍关闭；本批非空真实浏览器验收只用独立simontalk_test和测试准入，无供应商调用、无开发库种子。详见[契约](../architecture/2026-10-18-preparation-discard-api.md)与[验证](2026-10-18-preparation-discard-verification.md)。

后续已用独立测试库真实浏览器补验断连、真实提交后延迟响应、双标签账号切换与共享会话退出；没有发现确定业务缺陷，未修改生产代码。受控手工步骤、脱敏请求记录和截图见[失败/身份验收](2026-10-18-recovery-browser-failures-verification.md)。临时故障/测试准入不属于默认开发API，不能在实际库照搬测试种子或故障注入。

`lib/features/conversation/`提供有界内存投影，现由媒体控制器的归一化协议回调消费；`flutter test test/features/conversation test/features/realtime/practice_media_conversation_test.dart`验证文字修订、播放证据和生命周期。正文不写观测journal或浏览器存储，默认协议仍Unavailable，当前没有正式练习页。契约见[对话投影](../architecture/2026-10-18-conversation-projection.md)，实际测试与集成边界见[验证](2026-10-18-conversation-projection-verification.md)。

2026-10-20已增加原连接最终文字追加/精确确认与客户端分页读取：媒体只将已接受的final修订放入有界内存journal，偏好页“未结束练习”可明确查看/翻页/刷新已保存文字。独立不可变读取模型核验原账号/连接、修订及预算，空修订覆盖旧原话；AI生成文本始终标播放未知，不形成会话固化或反馈资格。此入口只读，实际准入/网关/协议保持关闭。测试`flutter test --no-pub test/features/conversation test/features/practice/final_transcript_recovery_test.dart test/features/practice/final_transcript_panel_test.dart`；真实浏览器使用独立测试库的临时账号，未给默认开发库写假练习。详见[文字存储](../architecture/2026-10-20-final-transcript-storage.md)、[读取契约](../architecture/2026-10-20-final-transcript-read.md)与[本轮验证](2026-10-20-final-transcript-read-verification.md)。新增文字组件深浅色/空态预览同样只用样例；使用既有镜像依赖缓存启动时加`PUB_HOSTED_URL=https://pub.flutter-io.cn`，预览生成目录异常先使用官方`flutter widget-preview clean`，不修改SDK。

2026-10-21新增受限正常end、无字幕输入登记和内存版本前缀/context确认门；异常stop/dispose仍立即释放。正常end离页后保留原账号收尾/pending，媒体已关且确认完成后可释放，无需为本地验证开启模型。运行`flutter test --no-pub test/features/realtime/practice_media_drain_test.dart test/features/realtime/practice_media_providers_test.dart test/features/conversation/conversation_output_tail_test.dart test/features/conversation/final_transcript_journal_test.dart`；Node还实际编译Dart桥验证beginDrain。具体[验证与边界](2026-10-21-bounded-media-drain-verification.md)，不代表正式练习页、供应商截断/完成信号或可信终止已具备。

组件预览位于 `lib/design/account_components.dart`，只展示品牌和按钮的深浅色，不连接服务、不申请媒体权限。品牌启动图标可以用 `uv run --with pillow scripts/generate_brand_icons.py` 重新生成，脚本与 Flutter 的绘制路径保持一致。

另有标题/错误及麦克风失败/等待的浅深色320宽、200%字号预览。2026-10-17默认Previewer实际发现6项，修复独立入口的包资产字体初始化后，卡片与外层标题中文均实际可见；此前空注册问题本轮未复现，不推定其根因。可运行`flutter widget-preview start --web-server --offline`并访问终端地址。连续更新时SDK热重载可能报错，字体缓存变化或报错后采用全局热重启/冷启动。未修改SDK或提交生成目录；证据与限制见[预览字体验证](2026-10-17-preview-font-verification.md)。

GitHub Actions配置了独立PostgreSQL、API检查和Flutter分析/测试/Web构建。按当前Web优先方向，已移除APK自动构建步骤。未推送之前，只能声称工作流已配置，不能声称远端CI已通过。

2026-10-21播放证据追加/分页已与媒体及账号作用域接通，契约见[播放证据接口](../architecture/2026-10-21-playback-evidence.md)。普通最终文字仍不包含可信AI播放状态；读取证据固定未固化/不可自动恢复，不开启媒体。独立实际HTTP用例`test/integration/playback_evidence_wire_test.dart`需要`SIMONTALK_PLAYBACK_WIRE_FIXTURE`指向含两个测试身份及原连接的本机隔离夹具，缺失时明确skip；夹具含凭证，不提交或输出，使用后精确清理临时账号/邀请/子数据。测试准入只能注入临时独立测试库API进程，不能替换开发准入。实测及清理证据见[验证报告](2026-10-21-playback-evidence-verification.md)。

2026-10-21[正常结束与固化接口](../architecture/2026-10-21-practice-finalization.md)使用原scope end+固定manifest；只有实际receipt才结清确认队列，缺失内容标sealed_unsaved并停止重试，封存不释放unknown占用。终止任务当前只登记blocked/0次，无可执行供应商核验。实际HTTP用例`test/integration/practice_completion_wire_test.dart`需`SIMONTALK_COMPLETION_WIRE_FIXTURE`本机隔离夹具，缺失明确skip；它实际等待31秒验固定窗口，凭证不得提交/输出，用后精确清理。步骤和证据见[结束固化验证](2026-10-21-practice-finalization-verification.md)。


2026-10-21恢复面板新增明确“查看保存状态/刷新保存状态”，仅GET completion、必要的历史origin及原连接termination-check。新增深浅色保存状态预览；`flutter test --no-pub test/integration/saved_status_wire_test.dart`默认skip，实际运行需`SIMONTALK_SAVED_STATUS_WIRE_FIXTURE`指向独立测试库API/两个原身份的本机凭证夹具，内容不可提交或输出，用后精确清理。当前核验只有blocked/0次，不会执行上游终止。[契约](../architecture/2026-10-21-practice-finalization.md#7-恢复入口的保存与核验读取)与[本轮验证](2026-10-21-saved-status-recovery-verification.md)。


2026-10-21新增[复盘输入本人API及内部引用门](../architecture/2026-10-21-review-inputs.md)，迁移4c913f2d8e71仅增加review_inputs，默认供应商仍关闭。原seal后POST `/v1/practice-sessions/{sid}/review-input`仅带input_revision与原input_hash，精确重放不重建；GET纯读。目标 `uv run --locked --no-sync pytest tests/test_review_inputs.py`，请求前8KiB/五秒边界回归也在该测试文件（复用offer_body_limit中间件）；新模型/规则不涉及Flutter或付费调用。数据夹具须独立测试库并精确清理，原用户库不可写假练习。[本轮迁移/HTTP验证](2026-10-21-review-input-eligibility-verification.md)。

2026-10-21新增[持久反馈任务与结果](../architecture/2026-10-21-review-jobs.md)，迁移8b2731f5ca90增加review_jobs/review_attempts/review_actions/review_results。POST `/review`绑定原ReviewInput，GET纯读，POST `/review/retry`核对job_id/expected_attempts与固定动作key。默认Unavailable，正常输入blocked/0次，不可评价零调用；lifespan独立ReviewJobRunner每5秒有界扫描，`SIMONTALK_REVIEW_JOB_INTERVAL_SECONDS`允许1–300秒，仅为调度间隔，不是调用或费用上限。目标`uv run --locked --no-sync pytest tests/test_review_jobs.py tests/test_review_worker.py`；注入gateway只用于独立测试库，不提供公网控制或写入反馈端口。结果来源、超时未知/幂等重试及清理范围见[本轮验证](2026-10-21-review-jobs-verification.md)。Flutter和实际供应商配置未改，用户删除/完整计量尚未实现。

2026-10-21新增`lib/features/review/`原账号[复盘任务客户端](../architecture/2026-10-21-review-client.md)，使用既有ApiClient与无依赖Dart模型；构造/监听不请求，明确requestReview、纯读refresh、retryGeneration与原动作retryPending分别处理。目标`flutter test --no-pub test/features/review`；浏览器平台可用`flutter test --no-pub --platform chrome test/features/review`。实际`flutter test --no-pub test/integration/review_client_wire_test.dart`需`SIMONTALK_REVIEW_CLIENT_WIRE_FIXTURE`指向本机隔离测试库fixture，缺失明确skip；含base_url、a/b/c原身份/connection/sealed completion及仅测试的gateway_mode_path/gateway_calls_path。凭证不提交/输出，使用后精确清理身份/数据/API及文件；模式文件不得成为产品端口。该批未接页面或真实模型，后端/迁移未改。[实测报告](2026-10-21-review-client-verification.md)。

2026-10-22[复盘阅读页](../architecture/2026-10-21-review-page.md)位于`/practice/:sessionId/review`，从本人sealed恢复摘要进入；重新加载仅GET来源/任务，不会自动创建或重试生成。相关source/view/selection/screen/preview回归同在`test/features/review/`；预览位于`lib/features/review/review_page_previews.dart`，通过既有字体wrapper展示浅三项、深320/200%字及blocked/空态。默认API仍Unavailable；有效建议仅在隔离测试库临时gateway下验页面，不把fixture接口接入应用。需使用`--dart-define=API_BASE_URL=...`时仅指向本机隔离API，验后恢复默认开发配置并清理测试身份/凭证/服务。[页面验收](2026-10-21-review-page-verification.md)。

### 已封存文字与定位开发入口（2026-10-22）

[已保存文字](../architecture/2026-10-22-saved-transcript.md)新增GET `/v1/practice-sessions/{sid}/saved-transcript`，带`input_revision=1/input_hash`及可选offset/limit/review_item_id，无迁移、依赖或供应商开关。普通页不要求review任务存在；后端改动后重启API。目标`uv run --locked --no-sync pytest tests/test_saved_transcripts.py`，客户端目标`flutter test --no-pub test/features/transcript test/features/review`；Chrome使用同路径加`--platform chrome`。新预览入口`lib/features/transcript/saved_transcript_previews.dart`，固定样例在独立preview_fixtures，不进入应用来源或请求分支。

真实HTTP夹具只能放独立测试库，不能将正文/凭证或gateway控制接口接到应用。实际普通/定位网址是`/practice/:sid/transcript`和`.../transcript/:itemId`，刷新只读，不触发review生成。默认构建继续API8000及Unavailable；本批隔离库/API8001/Web7357与临时凭证/脚本已清理。本批浏览器工具被Work设置禁用，未执行实际页面/Previewer点击；后续可用时需重新创建隔离数据补验，不能复用已清理凭证或以前页面截图冒充新页证据。[完整验证](2026-10-22-saved-transcript-verification.md)。


## 一级重练后端准备（2026-10-22）

[一级重练契约](../architecture/2026-10-22-rehearsal-preparation.md)新增来源item目标GET、确认hash后POST独立准备、子固定目标GET及同级元数据GET。运行上述迁移后重启API；目标测试为`uv run --locked --no-sync pytest tests/test_rehearsal_targets.py tests/test_rehearsal_preparations.py`。存在重练时迁移拒绝降级，不能绕过门静默删除来源信息。默认admission/信令/反馈仍关闭，不提供真实服务开关；隔离夹具不能放开发库或接入应用。没有新增Flutter入口或媒体提示词，后续接客户端目标确认与独立准备读取。[本批验证](2026-10-22-rehearsal-preparation-verification.md)。

2026-10-23新增入口wire用例`test/integration/practice_entry_wire_test.dart`，需`SIMONTALK_ENTRY_WIRE_FIXTURE`指向含`base_url`、`account_id`、`access_token`的本机隔离夹具；默认缺少时明确skip。仅验证生产默认Unavailable下current→创建503，不启用模型，不把夹具写入Git。用后精确清理专属库/身份和凭证。本批发布构建未指定API_BASE_URL，使用同源API；本地检查时应配置同源代理或按上文显式指定开发API地址。


## 本人历史读取（2026-10-23）

[历史契约](../architecture/2026-10-23-practice-history.md)新增GET `/v1/practice-history`及`/{sid}`，运行迁移到`2d4836ab9c10`后重启API。目标测试：`uv run --locked --no-sync pytest tests/test_practice_history.py`、`flutter test --no-pub test/features/history`。页面地址为`/history`和`/history/:sid`，无需模型/麦克风/先设难度。预览入口`lib/features/history/history_previews.dart`五态样例独立于产品查询。

实际wire：`SIMONTALK_HISTORY_WIRE_FIXTURE=/absolute/private-fixture.json flutter test --no-pub test/integration/practice_history_wire_test.dart`，缺少夹具明确skip。夹具需含`base_url/account_id/access_token/session_id/other_account_id/other_access_token`，只放本机独立测试库凭证；当前用例要求A23条/B1条及来源23段文字/已有1项复盘，不能对真实账号补造数据。用后精确删除专属库/凭证及服务。发布构建使用同源API；本地实际检查需同源代理或显式API_BASE_URL。浏览器工具本轮被Work设置禁用，实际点击与Previewer待补，不能拿组件渲染替代。[本轮结果与清理](2026-10-23-practice-history-verification.md)。


## 本人记录删除（2026-10-23）

[删除契约](../architecture/2026-10-23-practice-deletion.md)新增历史前缀下scope GET、DELETE及原key凭据GET，迁移到`3e5947bc0d21`后重启API。存在墓碑或凭据时拒绝降级，不能移除可见性门复活已删内容。目标：`uv run --locked --no-sync pytest tests/test_practice_deletion.py`、`flutter test --no-pub test/features/history`；预览入口`lib/features/history/deletion_previews.dart`四态独立样例。实际地址`/history/:sid/delete`，进入只读，保留/取消零写，明确确认才删除。

实际wire：`SIMONTALK_DELETION_WIRE_FIXTURE=/absolute/private-fixture.json flutter test --no-pub test/integration/practice_deletion_wire_test.dart`，默认缺夹具skip。夹具仅独立测试库，含`base_url/account_id/access_token/other_account_id/other_access_token/other_session_id/session_id/child_id/pending_child_id/connection_id/input_hash`；A父+两子（一安全取消/一unknown）及有效文字/复盘种子，B独立一条，绝不能写入真实账号。该测试确实删除种子并故意丢一次2xx回复，验原凭据和占用；重复执行需重建专属数据。用后精确删除专属库、凭证和进程。没有新模型或供应商开关，墓碑和删除凭据不等于完整用量/备份恢复系统。[结果与未验范围](2026-10-23-practice-deletion-verification.md)。

## 人工数据库备份与离线检查（2026-10-25）

[契约](../architecture/2026-10-25-backup-bundle.md)与[验证](2026-10-25-backup-bundle-verification.md)。在`services/api`核对当前Settings指向源库，提供可连接同一源库的PostgreSQL17工具，父目录预先建好并私有保管。目标必须是新的绝对目录，已有目标拒绝覆盖；默认工具阶段30秒、可选1–120秒，dump最多512MiB。

```sh
uv run --locked --no-sync simontalk-admin backup-create --output /absolute/private/backup-20261025 --pg-dump /absolute/tools/pg_dump --timeout-seconds 30
uv run --locked --no-sync simontalk-admin backup-check --input /absolute/private/backup-20261025
```

目录0700、三个文件0600；`database.dump`与`deletions.json`使用同一只读快照，`manifest.json`最后发布。保存输出manifest hash及可信来源。工具不自动停服；正常写入可继续，但快照后提交的删除不在此备份内。失败只清理本次文件，不覆盖或递归删除已有内容。

`backup-check`完全离线，不需有效Settings或可用数据库，返回完整性结果；`restore_verified:false`与`latest_deletions_verified:false`始终保留。不能把hash/header检查当实际恢复或清单最新性的证明。

恢复时先在隔离目标使用可信备份，例如以目标库明确配置的`PG*`环境执行`pg_restore --exit-on-error --no-owner --no-acl --dbname=restored_database_name /absolute/private/backup-20261025/database.dump`，核对schema与业务内容，再沿用下节停服/最新清单/预检/原子应用流程。包内清单仅为备份时刻，不可替代从最新权威库独立导出的清单；最新清单必须独立保管。自动调度、异地实时清单及保留期执行尚未实现。

### 真实恢复CI与本机入口

API工作流复用既有PostgreSQL17服务容器，以`job.services.postgres.id`生成临时`pg_dump/pg_restore`入口；pytest步骤开启`SIMONTALK_REQUIRE_REAL_BACKUP_TESTS=1`并配置两条绝对路径，缺任一路径直接失败，不能用skip代替真实恢复。工作流同时检查生成器的Ruff/格式。远端运行状态以GitHub实际check为准，[本轮本机证据与限制](2026-10-25-backup-ci-verification.md)。

需要本机重复同一测试入口时，在仓库根目录执行；父目录须已存在，输出目录必须是新的绝对路径，数据库必须另建且以`_test`结尾：

```sh
uv run --project services/api --locked --no-sync python scripts/prepare_test_postgres_tools.py --container "$(docker compose -f deploy/compose.yaml ps -q db)" --output /absolute/private/ci-pg-tools
```

然后在`services/api`设置`SIMONTALK_TEST_DATABASE_URL`指向该独立测试库，执行：

```sh
SIMONTALK_REQUIRE_REAL_BACKUP_TESTS=1 SIMONTALK_BACKUP_TEST_PG_DUMP=/absolute/private/ci-pg-tools/pg_dump SIMONTALK_BACKUP_TEST_PG_RESTORE=/absolute/private/ci-pg-tools/pg_restore uv run --locked --no-sync pytest -q
```

入口目录/脚本0700，固定Docker路径、容器ID及Docker配置HOME，连接密码仅运行时环境转发；内部连接127.0.0.1:5432。这是隔离测试容器的辅助工具，要求`PGDATABASE`以`_test`结尾；不提供生产恢复隔离或容器内SQL权限边界。Docker角色仍需有创建/删除隔离恢复库的权限。普通本地未启用required且未配置工具时，两项测试仍明确skip。用后删除本次工具目录和独立测试库，不删除既有开发容器/卷。

## 独立删除清单与离线恢复

[契约](../architecture/2026-10-23-deletion-restore.md)及[实测报告](2026-10-23-deletion-restore-verification.md)。API schema当前需`4f6a58cd2e32`；依赖不变，在`services/api`运行已有`simontalk-admin`入口。以下命令读取现有Settings：每次先核对`SIMONTALK_DATABASE_URL`指向源权威库还是隔离恢复目标，禁止把含凭证的URI写入日志/报告。不能在运行中的API/worker旁直接应用。

1. 停止源API、worker及全部写入，核对全部已受理删除已落库。指向最新权威库，执行导出；使用新的绝对路径，已有文件拒绝覆盖。清单必须与数据库备份独立保存，保留可信来源/截止时间及输出hash。没有删除也保存明确空清单。

   ```sh
   uv run --locked --no-sync simontalk-admin export-deletions --output /absolute/private/deletions.json
   ```

2. 保持服务停止，将选定旧备份恢复到专属隔离目标库；本轮实测使用PostgreSQL17容器内的`pg_dump -Fc`与`pg_restore --exit-on-error`。指向该目标运行`uv run --locked --no-sync alembic upgrade head`及`alembic check`。旧凭据不能完整回填时升级拒绝，核对原权威库/可信清单，不删除凭据绕过。

3. 同一目标先预检；stdout给出`applied:false`、清单hash、凭据/成员数、存在/缺失/将隐藏记录和缺账号数，零业务行写入。核对缺失数量与备份时间是否一致。

   ```sh
   uv run --locked --no-sync simontalk-admin replay-deletions --input /absolute/private/deletions.json
   ```

4. 确认目标数据库字面名称后执行应用；下例`restored_database_name`须替换为实际隔离库名。命令不自动切换数据库、不自动停服。冲突/锁超时/非法文件整体失败，无半批成功。

   ```sh
   uv run --locked --no-sync simontalk-admin replay-deletions --input /absolute/private/deletions.json --apply --confirm-database restored_database_name
   ```

5. 在隔离环境核对本人历史不含已删记录、旧正文/反馈404、其他账号保留、原key凭据可核对、unknown仍占用/blocked核验。再次应用应`newly_hidden_records:0`且业务行不变。再次导出并与原清单核对完整凭据，即使备份缺成员/账号也不能遗漏删除决定。检查通过后才按部署流程重开服务。

此流程要求维护者拥有可信且足够新的完整清单；SHA-256不是签名，不证明来源或最新性。源库和最新独立清单同时丢失时不能声称无数据复活的完整恢复；不要直接开放旧备份。自动备份调度、异地保管、自动流量隔离和保留期限执行尚未实现。实际媒体/模型仍关闭。

## 一级重练目标确认与准备

[客户端契约](../architecture/2026-10-23-rehearsal-client.md)及[验证报告](2026-10-23-rehearsal-client-verification.md)。普通复盘建议的“练这一句”只在ordinary核验通过后显示；`/practice/:sourceId/rehearse/:itemId`先GET目标，明确确认才登记独立准备，默认Unavailable仍503。未设日常难度只能看目标并去设置；本次override不绕过后端偏好要求。历史子目标位于`/practice/:childId/rehearsal-target`，只读且源失效会撤下目标。未知请求只在当前页生命周期内保留原key，离页不自动写入；未结束准备在首页恢复面板查看/清理。

目标测试`flutter test --no-pub test/features/rehearsal test/features/review test/features/history`；Preview文件`lib/features/rehearsal/rehearsal_previews.dart`四态。可选`SIMONTALK_REHEARSAL_RENDER_DIR=/absolute/path flutter test --no-pub test/features/rehearsal/rehearsal_previews_test.dart`以真实项目字体输出组件图，不代表浏览器验收。

实际wire：`SIMONTALK_REHEARSAL_WIRE_FIXTURE=/absolute/private-fixture.json flutter test --no-pub test/integration/rehearsal_preparation_wire_test.dart`。私有夹具仅专属测试库，需`base_url/account_id/access_token/other_account_id/other_access_token/source_session_id/item_id/control_path`；预置有效ordinary来源/封存/建议并将原测试连接置closed/confirmed。控制文件`enabled/admitted`仅由临时测试服务本地读取，初始false，明确测试启用test-only准入，不新增正式控制端口。测试故意丢成功回复，创建并安全取消两条同级；可用`SIMONTALK_REHEARSAL_WIRE_REPORT`输出安全断言。用后精确删除专属库、夹具/控制/凭证及服务，不能用于真实账号或供应商。默认缺夹具skip。

## 来源关联重练列表

普通历史详情→“查看关联重练”→`/history/:sourceId/rehearsals`，每页10条，明确翻页/刷新，子详情返回保持原页。来源反馈失效不影响列表；列表只读，目标是否可读仍由原目标端点决定。[契约](../architecture/2026-10-23-related-rehearsals.md)、[证据](2026-10-23-related-rehearsals-verification.md)。

常规测试`flutter test --no-pub test/features/rehearsal`；四态Preview在`lib/features/rehearsal/rehearsal_list_previews.dart`。可选`SIMONTALK_RELATED_RENDER_DIR=/absolute/path flutter test --no-pub test/features/rehearsal/rehearsal_list_previews_test.dart`导出项目真实字体组件图。

专用wire：`SIMONTALK_RELATED_WIRE_FIXTURE=/absolute/private-fixture.json flutter test --no-pub test/integration/related_rehearsals_wire_test.dart`，可选`SIMONTALK_RELATED_WIRE_REPORT`写安全断言。私有夹具需`base_url/account_id/access_token/other_account_id/other_access_token/source_session_id/empty_source_session_id/child_ids`；A为有效ordinary来源及21条实际API创建/取消的一级子，所有子使用相同created_at，child_ids按UUID倒序；B有独立空ordinary来源。原测试连接用夹具置closed/confirmed，来源反馈可invalidated，服务默认网关关闭。**此wire会明确删除第1页游标子及A父/剩余20子，只能用一次性专属库，不能传真实账号或共享开发库。** 读阶段必须先验证纯GET全行不变，wire后核对22墓碑/2凭据、B保留及正文清零，再精确清理专属库/token/临时服务。无夹具默认skip，不能算实际互通通过。

2026-10-24浏览器工具已恢复，指定页面/预览/回环的新增范围与限制见[本轮实测](2026-10-24-browser-acceptance-verification.md)。Widget Previewer空注册时可先停止服务，再执行`flutter widget-preview clean`并按当前缓存镜像重启；本轮重建注册49项，实际查看5项。预览字体回退警告保留，不能仅凭预览服务启动标完整通过。供应商准入仍关闭，下一步依据[资料复核](2026-10-24-qwen-realtime-readiness-review.md)核对真实退出、播放截断及已暂缓账号/预算条件。


## 2026-10-25 候选文本反馈与浏览器竞态

[浏览器补验](2026-10-25-browser-races-verification.md)新增真实scope409、删除回包迟到、文字翻页/刷新及保存状态共享8秒截止、在途返回；六张截图已逐张查看，不扩展为所有设备或全部竞态通过。

候选类`QwenReviewGateway`位于`services/api/src/simontalk_api/qwen_review_gateway.py`，契约见[配置/输入/HTTP/未知语义](../architecture/2026-10-25-qwen-review-gateway.md)，[验证](2026-10-25-qwen-review-gateway-verification.md)。当前`create_app`继续使用UnavailableReviewGateway；没有环境自动启用或公开切换入口，设置Key不会开启计费调用。真实启用前仍需核权限/地域/预算及人工语义抽查，不向客户端传长期密钥。

独立组件命令：在`services/api`执行`uv run --locked --no-sync pytest -q tests/test_qwen_review_gateway.py`。组合检查另指定**本轮独立**`SIMONTALK_TEST_DATABASE_URL`（名称以`_test`结尾），运行`tests/test_qwen_review_gateway_integration.py`；测试会清空目标库，不使用开发库或与其他测试共享正在运行的库。供应商只用MockTransport，实际API/SQL/worker不等于真实模型。无新依赖/迁移；Flutter/Node本单元未变化，不重标历史运行结果。


2026-10-25设置与异步账号范围已修补，见[契约](../architecture/2026-10-25-account-action-scope.md)及[验证](2026-10-25-account-action-scope-verification.md)。目标`flutter test --no-pub test/features/account`含142项；新增89页面/22异步，HTTP为MockClient。repository的restore可接stillCurrent，生产controller提供同操作门；偏好/退出请求固定原accountId，旧恢复不会修改共享API身份。无需后端/迁移/依赖或模型配置；本轮Web已重建，但实际浏览器Cookie/原生安全存储并发不以自动测试代替。


2026-10-25后续完成[登录/注册/重设操作范围](../architecture/2026-10-25-auth-operation-scope.md)和[验证](2026-10-25-auth-operation-scope-verification.md)。原`flutter test --no-pub test/features/account`现含196项；新25服务层+29页面。AccountRepository.scopedTo共享API且不关闭它，ApiClient可选stillCurrent回调为同步纯判断，默认null不影响其他请求。无新后端/迁移/配置开关或模型调用。


2026-10-25[账号实际浏览器补验](2026-10-25-browser-account-acceptance-verification.md)已用当前release及隔离SQL检查正常/跨标签/冲突/503/迟到恢复，临时库和代理服务已清理。代理只作测试控制，不能作为正式启动方式。注册/密码重设实际页面提交、精确浏览器版本及手机网络仍待验；没有新增生产代码、模型开关或依赖。

## 注册与重设实际浏览器证据（2026-10-25）

[补验报告](2026-10-25-browser-registration-reset-verification.md)覆盖真实注册/初设、重复邀请、无效/已用重设凭证、重设失败重试、全部旧会话撤销、旧密码拒绝/新密码登录及成功回包迟到离页。使用本轮独立测试库和127.0.0.1/localhost两个Cookie范围，凭证通过现有维护逻辑临时签发；未改允许来源、安全规则或生产配置，测试身份/服务/库用后清理。仅桌面IAB，不替代凭证自然过期、手机/版本/大陆网络矩阵；此前其他账号浏览器和自动测试数量仍是历史证据。

## 会话与限流边界实际浏览器证据（2026-10-25）

[补验报告](2026-10-25-browser-session-boundaries-verification.md)覆盖Web会话预置过期、维护禁用后的旧草稿401/恢复回登录、其他账号保留，以及默认10次账号/30次IP/600秒窗口下的真实429和Retry-After。仅在独立测试库预置A会话/C限流桶过期，不改应用时钟/配置，不冒充七天或600秒自然等待；直接HTTP预填与实际页面操作分开。原生输入拼接的一次401已排除并复验，测试身份/服务/库用后清理；自然长时到期、IP上限及设备/网络矩阵仍待验。

## 千问后端私有配置读取（2026-10-25）

最新已接[复盘供应商显式配置](../architecture/2026-10-25-review-provider-config.md)，[全量及真实后台runner验证](2026-10-25-review-provider-config-verification.md)。默认disabled；Key/workspace存在不会自动启用。需要启用时，在services/api目录保留现有私有.env，使用：

    SIMONTALK_REVIEW_PROVIDER=qwen uv run --locked uvicorn simontalk_api.main:create_app --factory --host 127.0.0.1 --port 8000

这会构造已抽查的qwen3.8-flash复盘网关，既有后台runner可处理合法排队任务；不会开启语音。私有文件位置可由SIMONTALK_QWEN_ENV_FILE指定，进程环境优先；无效启用配置在DB/runner前报稳定错误。禁用设disabled并重启，不能撤回已经发出的调用。实际日常.env本轮未写启用开关，默认服务没有启动。下方旧批次“没有环境启用入口/三Unavailable”保留历史范围，以本段及新契约为准。

后续[本人页面真实复盘验收](2026-10-25-real-review-browser-verification.md)用现有Web和标准后台runner完成2次真实生成：精确纠错/原话定位、正确句空结果、纯读不重调、503撤旧/恢复及换号409/404均已验。测试使用独立库和固定英文封存，6张截图与Token已留证，临时标签/服务/库已清理；没有改日常.env或应用代码，不代表真实业务语音、手机矩阵或广泛语义验收。

后续[真实建议到一级重练实测](2026-10-25-real-review-rehearsal-browser-verification.md)补完整原句/短引用、默认503零半写、测试准入下成功回包9秒迟到与同请求核对、仅本次难度、取消及两独立同级记录、子目标只读与重载。新真实模型1次，正式语音仍关闭；测试准入只用于隔离库的准备成功路径，不能部署为日常准入。7图/30条API元数据及Token已留证，环境已清理。

继续验证已补[真实合成音频上行、ASR、语音回复及真实复盘worker](2026-10-25-qwen-audio-worker-verification.md)：该报告明确区分真实WebSocket模型、ASR文字离线重放的业务范围和pytest的替身HTTP。新旧复盘型号均有六类实际SQL/worker组合回归；一次真实复盘空结果/用量、重启纯读及删除通过。截断请求本次没有得到确认，可信终止仍缺；不要因合成音频或离线重放成功开启正式语音。供应商尚待明确的问题见[询问稿](2026-10-25-qwen-upstream-capability-questions.md)，未自动联系他人。

后续已完成[真实WebSocket连接/语音生成/取消](2026-10-25-qwen-realtime-live-probe-verification.md)及[真实复盘候选验证](2026-10-25-qwen-review-live-verification.md)。这些是用户明确授权的受控小额实验，不是启动默认API后自动调用。复盘候选现支持显式qwen-flash/JSON Object和qwen3.8-flash/strict JSON Schema；两者继续严格本地校验，默认create_app未启用，也不随私有.env存在自动切换。旧型号本轮语义未通过，新候选只验了报告列明样本。取消缺用量保留未知，session.finish不能当本型号已验证退出路径。不要以本机CLOSED释放unknown占用或把测试文字写入个人记录。

将.env.example复制为services/api/.env后，Key和workspace只填私有.env，权限0600。SIMONTALK_QWEN_API_KEY、SIMONTALK_QWEN_WORKSPACE_ID为必填；SIMONTALK_QWEN_REALTIME_MODEL默认qwen3.5-omni-plus-realtime，SIMONTALK_QWEN_CONFIG_ID默认qwen-private-v1。此文件已被Git忽略，勿把Key放Dart构建参数、前端资源、报告或命令行。

2026-11-25 通话内主动求助独立使用 `SIMONTALK_ASSISTANCE_PROVIDER=qwen` 显式开启，默认 `disabled`。文本网关复用服务端的百炼北京工作空间和文本模型私有配置。启动前将目标库迁至 `19d7a3ec0b51`。 [主动求助验证](2026-11-25-live-assistance.md)

在services/api内显式调用`from simontalk_api.qwen_config import load_qwen_realtime_settings`，`settings = load_qwen_realtime_settings()`构造既有参数；也可传`env_file=绝对私有路径`，同名环境变量优先。不要打印settings.api_key或序列化原始私有配置；默认应用仍三Unavailable，不会因填Key或加载参数自动发送请求。[本轮验证及费用估算](2026-10-25-qwen-private-config-verification.md)。用户已确认首轮实测20元，但可信终止/用量与硬停费能力仍须各自验证，不能凭本地预算字段开放语音。
