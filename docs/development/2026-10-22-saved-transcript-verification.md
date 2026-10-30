# 复盘原话定位与整次已保存文字验证

日期：2026-10-22（Asia/Shanghai）。按[本单元设计](../superpowers/specs/2026-10-22-saved-transcript-design.md)和[计划](../superpowers/plans/2026-10-22-saved-transcript.md)，契约见[架构](../architecture/2026-10-22-saved-transcript.md)。后端、客户端、独立规格/质量审查、完整自动检查、真实HTTP和组件渲染已有下述证据。实际浏览器/Preview点击验收因Work设置禁用浏览器而未执行，保留为待补项，不据此标完整产品验收通过。

## 1. 后端与独立复核

新增本人sealed纯读分页及有效建议定位API，无依赖或迁移；main仅注册新router。真实首项RED为未实现404而预期200；扩展先37失败/1通过，额外全局coverage/gap摘要篡改2项200而预期409，再补本模块一致校验后通过48目标。未重写原来源/结果门。

| 检查 | 结果 |
| --- | --- |
| 新增`tests/test_saved_transcripts.py` | 48通过，12.37秒（格式整理前） |
| 实施agent完整API | 555通过，126.40秒 |
| root独立完整API | 555通过，114.96秒 |
| root Ruff check / format --check | 通过，76文件格式一致 |
| root Alembic metadata/head | 与迁移库一致，8b2731f5ca90 |
| 独立规格、随后质量审查 | 均通过，只读静态审查，未代替上述测试 |

覆盖匿名/本人/他人、X-Account-ID冲突、sealed/hash绑定、无ReviewInput/Job可读、纯GET无commit且业务全行相等、偏移/空终页/连续ordinal、多scope重复turn UUID、最新空修订、旧prefix/current final分离、unknown/not_played/revoked及revision0、有效result/quote/hash门、源删除/篡改、聚合预算在materialize前拒绝、实际JSON逃逸超过512KiB拒绝（更小页仍能读）。现有非成功任务暂不能定位为409；无任务或有效成功结果无此item为404。

根命令分别为`uv run --locked --no-sync pytest`、`ruff check .`、`ruff format --check .`。日志`/tmp/simontalk-saved-transcript-root-api.log`、`-ruff.log`、`-python-format.log`和`-metadata.log`为本机验证证据，不提交。

## 2. 隔离真实HTTP

使用专属`simontalk_saved_transcript_20261022_test`库、loopback8001、临时A/B账号及本地admission/signalling/review替身。账号/偏好/练习/连接/两账本/end/manifest及review全部经真实HTTP；邀请通过专属库创建。没有实际模型或媒体调用，生成建议明确标“界面验收夹具”，不能作为语言质量证据。

A包含两次连接：第一连接旧用户句后提交最新空revision2，第二连接复用同turn UUID并保留revision1原话；总计23段。有效建议初读focus.ordinal=19、offset=18、epoch=2，正确定位第二连接；从头页仍显示第一连接最新空修订，不恢复旧句。显式offset2携带同item读前16段，next18；offset23为合法空终页，offset24为422。旧AI前缀仍revision1，当前final为revision2，不补新后缀；播放独有revision0显示无final/unknown。

B没有ReviewInput/Job，普通读取2段成功。匿名401、B读A404、错误hash409、未知item404、X-Account-ID与实际身份冲突409。初次纯读前后业务计数相同：2账号/2练习/3连接/25最终转写事件/3播放事件/2completion/1input/1job/1attempt/1result/1action；review替身仅1次调用。额外在正常分页与这些失败请求前后，比较13张来源/业务表的完整JSON行（只在内存比较、不输出正文）相等。真实Dart控制器验证后再比较13表摘要相等、替身调用仍1次。详见本机`/tmp/simontalk-saved-transcript-http-proof.json`。本批没有实际浏览器操作。

## 3. 客户端、真实wire与独立审查

入口真实RED先复现sealed+blocked缺少“查看已保存文字”。额外先RED复现初页sealed_at/coverage/gaps与刚确认completion不一致仍被接受，再补严格绑定；合法空白播放前缀先被误拒也经独立RED修正。AI段卡ListTile的Material容器断言已按原因修复；正文收起/展开均验证没有liveRegion祖先，不把ExpansionTile自身展开状态播报误认为正文播报。新增解JSON前实际bodyBytes限额（包含空白）及新模型UTF-8字节/NUL/孤立surrogate边界，旧ApiClient默认无新上限。

新增8个生产文件与8个测试文件（含独立测试夹具），修改阅读路由、ReviewPageController导航资格、review screen/view回调和ApiClient可选上限。测试覆盖无job入口、三类实际建议定位、source/busy/item/账号再核对、初读共8秒/分页8秒、单飞/取消/dispose/迟到、分页网络失败保留原页、非法来源清空、首焦点及跨页锚、普通/定位网址、账号恢复/失联/无难度、incoming编码前进历史、返回复盘滚动、320/375/横向矮窗/两主题200%减少动画、48按钮、稳定刷新焦点、鼠标单/双/三击选择复制及隔离预览。

| 检查 | 结果 |
| --- | --- |
| 最终实施完整Flutter | 773通过、4原有skip，20秒；新增72项，没有新增skip |
| root独立完整Flutter | 773通过、4原有skip，29秒；产品最终源码一致，随后仅测试数值断言修正 |
| 最终实施VM目标 | review+transcript共163通过，7秒 |
| 最终实施Chrome目标 | review+transcript共163通过，30秒 |
| root最终Chrome目标 | review+transcript共163通过，29秒 |
| root analyze / Dart format | 无问题，2.2秒；148文件、0改动 |
| root Node Web检查 | 58通过，0skip |
| root真实Dart HTTP控制器 | 3通过，纯GET |
| 独立规格、随后质量审查 | 通过；只读静态审查，不代替运行证据 |

4个skip均为原有playback/saved_status/review_client/practice_completion集成测试缺少各自隔离夹具环境变量，未把跳过记成功。真实Dart临时wire独立使用本单元A/B：初次两GET直接定位第19段/epoch2；显式模拟分页传输失败保留同一已接受对象，重试原offset2成功并保留AI旧revision1/current2；回原话及刷新同步清旧；B无job两GET可读；B读A来源404只发一次GET、没有第二页请求。请求全部GET，没有调用review路径；它包含本地显式传输失败，不冒充自然发生的网络故障。

root第一轮Chrome162通过/1失败，隔离RED定位`total_turns=1.0`断言：Dart Web把数学整数1.0视为int，VM区分double。只修测试通用非法值为1.5，并保留VM专有1.0严格断言与true/负数/超界拒绝；产品解析逻辑未改。root首轮Node因漏将Dart加入PATH导致编译桥接未启动，补齐PATH后58通过，未改源码。

质量审查覆盖生产代码、ApiClient默认兼容、路由与主要测试，未逐行读辅助`transcript_fixtures.dart`；root随后完整读该夹具。静态审查与运行验收分别记录。

日志包括`/tmp/simontalk-saved-transcript-{root-full,chrome-final,root-analyze,root-format,node-final,wire}.log`；实施最终日志前缀`/tmp/simontalk-transcript-numeric-`。临时wire脚本和凭证验后已删除，没有将夹具接口接入应用。

## 4. Web与可视证据边界

隔离API8001发布构建通过37.2秒，完整字体校验通过：30,890映射、WOFF2为7,782,072字节，发布目录包含本地Roboto。随后恢复默认API8000发布构建通过39.7秒，最终字体复核同样通过；日志`/tmp/simontalk-saved-transcript-web-final.log`及`-fonts-final.log`。构建未部署或对外公开。

尝试打开本单元本地页面时，浏览器工具直接返回“Local browser use is disabled in Work settings”。没有获得标签或页面状态，也没有实际执行浏览器定位、翻页、返回、断网或跨标签身份操作；Previewer未启动。这是当前工具/设置限制，不据自动测试推定这些手工流程已验。后续浏览器可用时须重建隔离夹具，补完计划Task3的实际页面/Preview验收。

补充使用Flutter widget测试离屏渲染四个真实纯视图预览，额外4项通过：浅375×1100、深320×900/200%文字、空375×812、错误375×812；深色另滚到原话段。实际查看所有PNG，文字、换行、按钮和目标轮廓正常。测试环境默认Ahem会把字符画成方块，临时渲染脚本显式加载本地完整NotoSansSC TTF及MaterialIcons，并将同一主题文字family指向该字体后重渲染；没有更改产品字体/主题。图片是组件示例渲染，含固定例句，不能作为实际浏览器、真实账号记录或模型质量证据。

本机非敏感图片：`/tmp/simontalk-saved-transcript-widget-light.png`、`-dark-large.png`、`-dark-target.png`、`-empty.png`、`-error.png`；日志`/tmp/simontalk-saved-transcript-render.log`。临时渲染脚本已删除。

## 5. 清理与剩余工作

隔离账号/邀请及所有业务数据随专属测试库删除；API8001和Web7357停止，临时凭证/控制文件/fixture与seed/wire/render脚本及fixture字节码均删除。没有创建本轮浏览器标签。保留非敏感日志/HTTP计数证明和组件渲染图。默认API8000重启后live/ready正常，新路由匿名401、真实准入/信令/review仍Unavailable。

默认开发库head仍8b2731f5ca90，17张表计数与本轮开始完全一致：1用户、1邀请、11认证会话、1偏好，其余业务表均0。本轮无迁移、依赖、锁文件或提交/推送/部署。实际浏览器/Preview验收仍待补；真实语音、可信终止、真实反馈、一级重练、完整历史和删除仍未完成。

最终`git diff --check`通过，47份本轮及前轮保留改动的Markdown共386个本地链接/标题引用与围栏检查通过；两端锁文件未改。交接/总纲/交互/视觉/技术/本地开发/路线/验证均已同步实际范围和未执行项。
