# 基础页面浏览器补验与本地媒体回环

日期：2026-10-24（Asia/Shanghai）。本轮按[基础路线](../superpowers/plans/2026-10-22-basic-version-development.md)连续完成实际页面补验、Widget Previewer与既有WebRTC回环。此前报告的浏览器禁用是当时事实；本轮工具已可用，以下是新增证据，不追改旧报告的实测记录。

## 环境与边界

使用本机ChatGPT应用内浏览器、当前源码重新构建的Flutter Web release，以及独立测试库`simontalk_browser_20261024_c7e51_test`。Web7357代理到API8001，主机均为127.0.0.1，真实Cookie/CSRF、生产路由/仓库/控制器和PostgreSQL参与；默认API8000未运行，本轮没有启动它。浏览器工具未提供可核实的引擎版本，本轮不宣布某个Chrome/Safari最低版本受支持。

A账号24条测试记录（普通来源1、一级重练2、同时间普通21），B账号1条；来源23段文字及1项反馈均为独立测试样本。仅种子阶段使用既有测试准入、生产封存/worker和明确测试Gateway；为派生重练使用测试fixture关闭状态，随后人工设置unknown以验页面占用边界。这些状态不是供应商或可信终止证据。实际对浏览器提供的应用始终使用UnavailableAdmission、UnavailableSignallingGateway、UnavailableReviewGateway。

本轮没有修改应用源码、schema、依赖或默认准入；没有供应商请求、物理麦克风许可、原生构建、提交、推送或部署。

## 实际页面结果

| 场景 | 实测结果 |
| --- | --- |
| 登录与历史 | A经真实登录进入首页；历史三页10/10/4，末页禁用下一页，可回上一页、打开普通详情。列表区分准备取消、已保存和连接待核对 |
| 每次保存情况 | 从详情进入，显示原难度、保存完成及独立的连接/用量待核对；浏览器刷新保留原深链接并恢复账号与读取 |
| 保存文字分页 | 23段按16+7读取，最后一页无下一页；正常详情返回可用 |
| 翻页失败/恢复 | 测试代理返回标准503/service_unavailable；翻页失败保留原页并说明，主动刷新失败清除旧正文；恢复代理后明确刷新成功。首轮自定义test_api_offline错误码不属于生产协议，已纠正夹具，不将其清除行为当产品缺陷 |
| 复盘与定位 | 阅读已有测试反馈，没有创建新反馈任务；定位到真实第23段及精确引用，浏览器后退/前进可回到原定位网址 |
| 重练目标 | 从建议进入确认页，完整原句、关注片段及本次难度可见；确认后真实409/practice_in_progress，unknown阻止新建 |
| 关联记录 | 展示2次一级重练，进入子详情、只读目标及来源详情；没有自动开麦或生成反馈 |
| 窄屏与键盘 | 实际视口320×740、DPR1下查看目标/删除/恢复状态；Tab从重新读取目标移到返回按钮，Enter返回子详情。属于桌面视口，不代表手机设备 |
| 单删重练 | 第二标签删除一次重练，返回历史并提示删除1条；来源及另一条同级保留 |
| 跨标签CSRF | 另一标签写入轮换共享CSRF Cookie后，旧父删除收到403，页面要求重新读取；明确重读展示当前父+1子共2条。旧退出同样403并保留登录，明确刷新再确认后退出成功，没有自动重放 |
| 删除成功但丢回包 | 测试代理在上游DELETE成功后断开回包；页面显示结果尚未确认，不自动再DELETE。点击核对通过GET凭据确认，返回历史并提示内容已删、连接/用量仍待核对 |
| 删除后旧地址 | 原详情、原话定位与复盘实际返回不可用；不再展示原正文/反馈。另一个标签的缓存列表经读取后更新 |
| 删除后占用 | 首页恢复面板仍读到unknown和内容已删除，开始按钮禁用；正文删除没有解锁未知连接 |
| A/B身份变化 | 第二标签明确退出A、登录B，只见B的1条记录；旧A标签刷新收到GET409、清除旧恢复快照并要求重新确认，确认后只见B记录 |
| 默认语音失败 | B无占用，进入普通准备并通过Enter开始，真实POST503/realtime_unavailable；没有新增练习或连接，没有设备许可或假通话状态 |

本轮未在浏览器专门复现删除scope409并发、超时8秒、所有旧回调竞态或手机生命周期；相应已有自动/HTTP证据继续保留。没有将上述有限页面场景算成全部B1–B6验收。

截图：[历史](screenshots/browser-acceptance-history.png)、[保存情况](screenshots/browser-acceptance-save-status.png)、[翻页失败保留原页](screenshots/browser-acceptance-transcript-page-failure.png)、[第23段定位](screenshots/browser-acceptance-transcript-focus.png)、[320目标](screenshots/browser-acceptance-target-320.png)、[删除范围](screenshots/browser-acceptance-delete-scope-320.png)、[丢回包](screenshots/browser-acceptance-delete-unknown-320.png)、[删除后unknown](screenshots/browser-acceptance-deleted-unknown-320.png)、[默认不可用](screenshots/browser-acceptance-default-unavailable.png)。

## Widget Previewer

首轮实际页面显示No previews detected。停止后运行官方`flutter widget-preview clean`，按仓库现有镜像缓存设置重建；生成注册表49项，实际筛选并查看以下5项，不修改SDK或生成器：

- 历史浅色列表及深色320/200%字号，查看记录卡和分页区。
- 删除深色320/200%字号，Tab将焦点移到确认按钮，页面滚动使其可见。
- 已保存文字深色320/200%字号，展开生成全文；旧修订播放片段与当前生成全文仍有不同标签。
- 保存结果缺口深色320/200%字号，滚动查看具体缺口、刷新和连接/用量独立提示。

截图：[历史浅色](screenshots/browser-acceptance-preview-history-light.png)、[历史大字](screenshots/browser-acceptance-preview-history-320-200.png)、[历史下部](screenshots/browser-acceptance-preview-history-320-200-bottom.png)、[删除大字](screenshots/browser-acceptance-preview-delete-320-200.png)、[确认操作](screenshots/browser-acceptance-preview-delete-320-200-bottom.png)、[文字大字](screenshots/browser-acceptance-preview-transcript-320-200.png)、[生成全文展开](screenshots/browser-acceptance-preview-generated-text-320-200.png)、[保存缺口](screenshots/browser-acceptance-preview-save-gap-320-200.png)、[保存下部](screenshots/browser-acceptance-preview-save-gap-320-200-bottom.png)。

预览控制台有Noto Sans TC本地回退404和缺字回退警告；本轮已查看截图中的中英文可见，不把这些警告写成已修复，也不宣称全部字符覆盖已实测。实际发布页检查到的控制台error/warn列表为空，发布字体另由完整映射校验确认。预览仅样例，不连接业务API。

## 真实浏览器媒体回环

在7358执行仓库既有`test/web/realtime_loopback.html`，使用同一生产`web/realtime_transport.js`，合成静音输入和两个真实RTCPeerConnection。页面一次运行通过ICE/SDP、双端DataChannel、测试配置确认后上行、静音/恢复、音轨ended及幂等关闭/信令取消；[实际页面](screenshots/browser-acceptance-webrtc-loopback.png)。没有物理麦克风、真实下行声音、自然插话、模型或可信远端终止证据。此项不把B2勾成完成。

## 检查与数据保护

- 当前Web release重新构建通过，编译38.2秒；发布字体校验30,890映射及本地Roboto通过。
- 没有应用代码变化，不为本文重跑全量Flutter/API/Node测试；先前1236/808/58均是历史结果。
- 阅读阶段的业务网络请求为GET；唯一重练创建尝试409，默认普通创建尝试503。两次成功删除分别影响1条、2条，父回包丢失后的确认仅GET。
- 最终A仍可见21条旧普通记录、删除墓碑3条；B唯一记录保留。最终文字、反馈输入/任务/结果均0，删除凭据2；连接仍unknown。种子未经过真实信令，因此没有termination_checks登记，不虚构blocked核验任务。
- 开发库20张业务表及alembic_version全行排序摘要前后相同。脱敏[数据库与请求证据](evidence/2026-10-24-browser-acceptance.json)不含密码、Cookie、token、SDP、原话或数据库连接串。

本轮限定场景未发现需要修改生产代码的确定缺陷。临时服务、库、账号/凭证及脚本的清理结果见证据文件；浏览器版本、真机/大陆网络、全部竞态与实际供应商仍需对应验收。后续可信退出与截断核查见[准入资料复核](2026-10-24-qwen-realtime-readiness-review.md)。

最终收口：独立库已删除并核实不存在，8001/7357/7358及两个Preview端口关闭；开发8000保持未运行。16个本轮临时文件与两个临时构建/状态文件已清理，开工Git状态列出的396个已有变更文件均存在。四个实际测试标签关闭；最初连接失败的临时错误标签因工具对内部data网址的限制，关闭未能独立核验，未标保留。7份相关文档283个本地引用、19张截图与`git diff --check`通过。应用源码/依赖未改，不宣称完整基础版本或所有浏览器场景完成。
