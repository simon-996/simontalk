# Flutter Web 单连接语音验证

隔离应用使用 Flutter release 编译的 Dart 入口、项目的 ApiClient、浏览器媒体会话、AudioWorklet 和 PCM 播放器。临时 PostgreSQL 保存练习与连接；同源应用使用实际 CSRF 路由、WebSocket 握手、主管与消息泵。Chromium 提供虚拟麦克风，输出静音。千问连接使用有固定事件顺序的替身。

| 检查 | 验证方法 |
| --- | --- |
| 采集门 | Node 事件测试检查开连接时只有认证帧，收到 ready 才请求权限；提前收到业务事件时关闭。 |
| 晚到授权 | 权限仍在等待时分别模拟换号、断开和页面隐藏，授权返回后检查轨道恰好停止一次、没有解除静音。 |
| 从输入到回复 | 在 Chrome 中从真实 Web Audio 轨道经工作线程送出 PCM；替身收到首帧才产生用户话轮，收到回复请求才发送回复和音频。 |
| 插话与停轨顺序 | Chrome 中检查隔离通知到达 Dart 时回复音源已经停止、麦克风轨道仍为 live。分别切换 ApiClient 账号、触发页面隐藏事件、断开上游，检查同一轨道变为 ended。服务端验证一次取消和关闭，以及 unknown 核验状态。 |
| 回复归属 | Node 用例检查旧回复隔离后的迟到音频被丢弃，错配的隔离通知关闭采集与播放。 |

可用 `flutter build web --no-pub --no-web-resources-cdn -t test/web/browser_media_loopback_entry.dart -o <临时输出目录>` 从客户端目录构建隔离入口。后端测试使用 `SIMONTALK_FLUTTER_MEDIA_BUILD` 指向该目录，`SIMONTALK_TEST_BROWSER` 指向 Chromium 可执行文件，`SIMONTALK_TEST_DATABASE_URL` 指向以 `_test` 结尾的专用测试库。运行 `tests/test_flutter_browser_media.py` 可重验三条完整路径。

本批范围是可由通话协调器持有的一次媒体连接。实际账号变化由 ApiClient 观察，跨标签远端撤销沿用服务端身份复验。真实用户授权交互、物理设备收听、通话页操作、真人多轮与真实千问均待验；页面隐藏用浏览器事件模拟。正式语音准入保持关闭。

本轮 Flutter 全套测试 1,559 项通过、10 项跳过，账号与凭据定向复跑 10 项通过。Node 浏览器测试 118 项通过。后端与浏览器定向 40 项通过，含编译客户端三条路径和原有两条浏览器回环。Flutter analyze、正式和隔离入口的 Web release 构建及两份后端测试的 Ruff 检查通过。测试容器已移除，无真实供应商调用、推送或部署。
