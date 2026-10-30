# 普通练习首页与准备入口验证

日期：2026-10-23（Asia/Shanghai）。对应[设计](../superpowers/specs/2026-10-23-practice-entry-design.md)、[实施清单](../superpowers/plans/2026-10-23-practice-entry.md)及[基础路线B1](../superpowers/plans/2026-10-22-basic-version-development.md)。

## 本批交付

- 登录且已设置难度默认进入`/practice`，显示本人实际难度、自由聊天、我的设置及既有只读恢复面板；无未实现的记录/话题/重练按钮。
- `/practice/prepare`可独立刷新，进入不请求API或麦克风。明确开始后先GET本人current，无占用才使用原准备/连接登记控制器。已有占用及读取失败阻止创建，明确刷新仅GET。
- 默认503显示实际语音未就绪；隔离替身成功只显示登记状态，取消/后台/离页沿用安全清理。准备不明时明确确认原key/body，不自动新建。
- 首页/准备/设置地址在恢复登录和后端不可达时保留，并呈现恢复状态。已有复盘/文字路由及编码浏览器历史保留；设置明确返回时确认未保存修改。
- 新增5个生产文件（入口协调器、provider、视图、页面与预览）、3个目标测试文件和1个实际HTTP用例；修改现有路由、设置、恢复面板及2个回归测试。后端、数据库schema与锁文件未改。

## 自动与独立检查

| 检查 | 本次结果 |
| --- | --- |
| 开工基线 | 原账号/准备/恢复面板52项通过 |
| RED | 新入口控制器最初缺失；页面测试实际断言默认`/practice`而旧行为为`/account`，失败已观察 |
| 最终入口目标 | 控制器/页面/预览41项通过，覆盖初始零请求、顺序、单飞、已有unknown、读取失败、503、原key确认、成功取消、后台/取消/身份/销毁迟到、浏览器pop、设置、地址恢复、键盘与宽窄/横屏/深浅/200%字号 |
| 含原账号/复盘/文字目标回归 | 中间批83项通过；最终全量覆盖后加的3项回归 |
| Flutter全量 | 814项通过，5项专用HTTP夹具缺少时按原规则skip；新增HTTP用例另行提供真实夹具通过，不把skip算成功 |
| 实际HTTP入口用例 | 1项通过；普通WidgetsBinding执行真实网络，不使用TestWidgetsFlutterBinding的HTTP400替身 |
| 静态分析/格式 | `flutter analyze --no-pub`无问题；157个Dart文件格式检查无修改 |
| Node | 58项通过，含实际Dart→JS桥编译 |
| Web release | `flutter build web --release --no-pub --no-web-resources-cdn`通过，最终55.7秒；同源API构建，未声明性能达标 |
| 字体 | 发布包完整映射30,890、压缩中文字体与本地Roboto核验通过 |
| 独立审查 | 按requesting-code-review做只读独立审查，独立目标39项通过；未发现剩余确定问题。提出的pop竞态未复现，新增根任务回归保留；后加成功取消/身份切换最终由root目标及全量覆盖 |

实施中修正1处生产代码及2处测试的花括号风格问题；原设置用例明确打开`/account`，首次设置后改为预期首页，原离线复盘返回用例改为保留`/account`并显示恢复状态。恢复中的持续进度动画用定量pump验证，不等待无限动画settle。没有通过删断言掩盖功能失败。

## 实际HTTP与数据库

创建专属随机名`simontalk_entry_*_test`，迁移到现有head `1a6de74c9f20`；仅此临时库创建1个验收身份，使用生产默认Unavailable准入/信令/反馈网关启动API8001。未注入允许准入，不启用供应商。

实际Dart入口协调器：GET `/v1/practice-sessions/current`取得空快照 → POST `/v1/practice-sessions`收到503 `realtime_unavailable`。重复begin/不适用retry不再发请求；没有POST连接。真实浏览器同样通过账号API登录并核对拒绝状态。

最终临时库：1用户、2认证会话（wire移动会话和浏览器Web会话），**0练习、0连接**。默认开发库19张业务表的计数与开工快照一致。脱敏摘要见[HTTP证据](evidence/2026-10-23-practice-entry-http.json)，没有保存密码、Cookie、token或数据库连接串。

## 实际页面与预览

使用本机内置浏览器打开最终Web release，临时7357同源代理仅连接隔离API8001。均为桌面浏览器与loopback验证，不代表手机设备或大陆音频网络验收。

- 实际登录后到首页，显示已保存的“轻松起步”；点击进入准备页。
- 明确开始显示真实“实时语音尚未就绪”，没有录音许可请求或假通话状态；刷新仍在准备地址并回到未开始，不自动创建。
- 320宽实际Tab聚焦“开始准备”、Enter得到503；返回首页，设置本地改选“自然交流”，返回弹出放弃确认，确认后首页仍用已保存难度。
- 实际浏览器后退回首页、前进到准备，均不自动创建；最终发布构建再次刷新/开始/返回复验。
- 实际Widget Previewer筛选并查看浅色首页、320深色200%字号（内部滚动到主操作）、未开始准备和不可用准备四项。预览只用纯视图样例，不依赖账号或API。

截图：[桌面首页](screenshots/practice-entry-home-dark.jpg)、[320首页](screenshots/practice-entry-home-320.jpg)、[真实不可用](screenshots/practice-entry-unavailable.jpg)、[320键盘后结果](screenshots/practice-entry-unavailable-320.jpg)、[首页预览](screenshots/practice-entry-preview-home.jpg)、[准备预览](screenshots/practice-entry-preview-prepare.jpg)。

## 清理、边界和下一步

两个本轮浏览器标签已关闭，临时API8001/Web7357/Preview65163已退出并检查端口关闭；专属临时库已删除并核实不存在，临时凭证/连接配置/脚本已删除。开工时原API8000未运行，本轮未启动、重启或修改默认开发服务；原库/原账号保留。

本批仅完成B1入口与准备，真实语音、正式通话/结束保存页、可信供应商终止及真实模型反馈仍缺。成功准备、unknown与清理场景的非空内容仍为明确测试替身；未宣称真实设备、媒体或费用能力。前批保存文字页的实际定位/分页/跨标签验收继续独立保留待补，不因本次浏览器可用直接标完成。

下一步B2仍需账号/地域/预算；按路线先推进无需模型的B3本人历史列表与详情，再做B4删除。当前功能分支和全部原改动保留，本批未提交、推送、部署或调用模型。
