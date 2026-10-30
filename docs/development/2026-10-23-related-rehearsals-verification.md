# 关联重练列表验证

日期：2026-10-23。持续开发授权下，按[设计](../superpowers/specs/2026-10-23-related-rehearsals-design.md)及[计划](../superpowers/plans/2026-10-23-related-rehearsals.md)实现[列表契约](../architecture/2026-10-23-related-rehearsals.md)。只改Flutter和文档/验证，后端/schema/依赖不变，保留原有工作区。

## 交付与自动检查

普通历史详情可进入独立关联列表，10条分页、只读元数据、子历史返回保留页和滚动。严格不可变模型/owner与parent/本地跨页边界、8秒单飞/取消、网络保留原页及确定失效清空已接入；来源复盘失效仍可列出，子详情不提供二次派生入口。

| 检查 | 实际结果 |
| --- | --- |
| 历史/重练开工基线 | 121通过 |
| 新模块TDD | 缺失模型/控制器RED→30项通过；缺失provider/路由RED→核心及页面40项通过；4态Preview另验通过 |
| 最终Flutter全量 | **982通过，9项专用夹具默认skip，约32秒**；新增44项常规测试及1项专用wire |
| 真实Dart→HTTP→PostgreSQL | wire 1项另验通过，不计入默认skip成功 |
| 分析/格式 | 无问题/2.1秒；206 Dart文件格式符合 |
| Node | 58通过，含实际Dart编译桥接 |
| Web/字体 | release构建33.4秒；30,890完整映射、7,782,072字节WOFF2和本地Roboto通过 |
| 独立只读审查 | 核对模型/分页锚、生命周期/取消、旧按钮、焦点与返回，未发现确定缺陷 |

测试覆盖损坏/额外字段、跨账号/父、重复/倒序、同时间UUID和跨页边界；三页/回退、单飞、网络保留/刷新清旧、401/404/409/非法响应清空、游标失效、单调及真实8秒截止、账号变化/dispose和晚回复。页面验证普通入口与子无入口、深链接/重连、未设偏好只读、旧回调身份、翻页焦点/Tab及子详情返回不重读、320/200%与横向布局。

一次验证命令漏加`--no-pub`触发依赖解析，已停止并用开工摘要核对的原锁文件恢复，随后`PUB_HOSTED_URL=https://pub.flutter-io.cn flutter pub get --offline --enforce-lockfile`还原原依赖。上表最终全量/分析/Node/Web、字体、组件渲染及新专属库的HTTP/wire均在原依赖下重跑；不使用中间变更依赖的结果。

## 实际HTTP与数据库

仅用专属隔离库。A普通来源保存/封存原话，使用既有准入/建议夹具产生有效item；原测试连接置closed/confirmed，属于夹具设置，不是实际供应商终止证据。通过实际API创建并取消21条一级子；统一子created_at为父创建后1微秒，以同时间验证UUID排序，将来源job置invalidated。B有独立ordinary来源且无子。8001服务所有实际网关保持Unavailable，无供应商调用。

先独立纯GET检查：

- A三页10/10/1，21条唯一ID与预置UUID倒序完全一致。
- 来源反馈invalidated仍200；B读A404，child作为parent409，其他来源游标404，B自身空列表200。
- 读取前后全部20业务表的数量和逐行摘要一致。

[HTTP证据](evidence/2026-10-23-related-rehearsals-http.json)。

随后真实Dart控制器验证三页/回退到第一页、B空列表与隔离。读阶段仅GET。为验证失效，测试明确调用既有DeletionController删除第1页末游标子：下一页收到`rehearsal_cursor_not_found`并撤下旧页，刷新从头读取剩余20条；再明确删除父及20条剩余子，刷新404且清空，B仍空列表可读。两个DELETE仅作用于一次性夹具；列表产品本身没有写请求。[wire证据](evidence/2026-10-23-related-rehearsals-wire.json)。

最终专属库23练习中22墓碑（A父+21子），2条删除凭据，B原普通记录保留；保存文字/复盘任务/结果均0，子目标均清为空对象，保留1条原测试连接。最小安全记录保留不代表练习内容仍可读。[数据库证据](evidence/2026-10-23-related-rehearsals-database.json)。

## 组件和浏览器

四态Preview不导入正式页面；导出时测试harness加载项目Noto替代Ahem。已查看浅色、深320/200%顶部和操作区、空态及保留原页的失败态五张图，换行正常、无溢出，按钮可滚动到达并有语义。最终原依赖下已重新渲染。

- [浅色](screenshots/related-rehearsals-render-light.png)
- [深色320/200%](screenshots/related-rehearsals-render-dark-320-200.png) / [操作区](screenshots/related-rehearsals-render-dark-320-200-actions.png)
- [空列表](screenshots/related-rehearsals-render-empty.png) / [翻页失败保留原页](screenshots/related-rehearsals-render-failed.png)

浏览器工具本轮返回`Local browser use is disabled in Work settings`，未创建标签或启动Web/Preview服务。实际页面/Previewer点击、浏览器Cookie、真实键盘和辅助技术待工具可用后补验，不能用widget路由或组件图替代。

## 保留与清理

开发库仍head`4f6a58cd2e32`，20业务表全行/数量与开工完全一致；原账号保留、练习/连接/删除凭据均0。全部后端原文件、两端依赖与锁文件摘要不变，587个开工文件均保留。[开发保留证据](evidence/2026-10-23-related-rehearsals-development.json)。后端未改，本轮不重跑API，上批709证据保留。

两次专属库（包括依赖修正前一次）均已精确清理，私有token/fixture和种子/服务/检查脚本删除，8001已停；8000保持未运行，没有Web/Preview进程或标签遗留。原分支与既有改动保留，未提交/推送/部署、未构建原生或调用模型。

本单元完成关联回看工程，不把准备/取消状态算通话完成。真实语音、改善评价、实际浏览器/设备及基础版本整体验收、自动备份和成本仍未完成。
