# 复盘入口与阅读页验证

开始于2026-10-21，最终验收于2026-10-22（Asia/Shanghai）。分支`feat/account-foundation`，保留全部原有未提交工作。本批按[设计](../superpowers/specs/2026-10-21-review-page-design.md)/[计划](../superpowers/plans/2026-10-21-review-page.md)接通[来源协调和阅读页](../architecture/2026-10-21-review-page.md)，另修复浏览器验收暴露的新连接时间顺序边界。没有模型适配、媒体、迁移、依赖/锁文件或原生改动，没有提交、推送或部署。

## 范围与回归

新增5个生产文件（来源控制器、screen、纯视图、preview、独立preview fixtures），修改review provider/router/恢复面板入口。URL只含练习ID；来源GET后才复用原客户端。来源与任务分别独立8秒，刷新撤下旧显示，同target保留原pending。初进只GET，整理/明确重试/原动作确认不绕过既有身份、409、未知调用或次数门。

实施者先跑sealed入口行为RED：期望“查看复盘”一项，实际0项；实现后GREEN。最终新增5个测试文件58项，加既有恢复面板1项，共59项。包含来源绑定/ending/缺失/非法/8秒/两个独立阶段/迟到/身份、同target pending、读取撤旧/确定冲突、实际screen/provider/route恢复返回、九态动作、三类长文选择/键盘/语义和四预览。320/375/844×390/1200×800、深浅色、200%文字与减少动画组合无布局异常。

独立规格审查修正主状态分区heading并补语义断言。实际浏览器再暴露URL和焦点问题；独立质量复审进一步补到未设难度账号及前进历史，两类均先RED后修。最终规格和质量复审通过。审查均只读，不代替实测。

- URL RED：push后页面是review，实际浏览器地址及restoreRouteInformation却仍为/account。固定go_router18.1.0的URL选项在router生命周期明确启用、dispose恢复原值。账号恢复和编码前进历史以incoming合法review URI/Map判断，不用当前页面猜目的地；B有/无难度、显式account/setup返回及signedOut登录门均补回归。
- 焦点 RED：320×568键盘刷新后，源读撤旧使scroll收缩，三卡回填将仍focused按钮推到1710（200%为2988）离屏。动作行移至稳定标题后、所有动态内容前，4组回归GREEN；没有固定栏或自动抢焦点/滚动。
- 时间 RED：B恢复current返回200，但连接DB默认created_at比应用last_seen_at晚0.729毫秒，严格Dart拒绝。新连接创建、heartbeat、45秒lease复用已有应用stamp；独立落后一秒的回归先失败，再验证GET/同key重放不更新时间。没有放宽Dart门、修改旧记录或增加迁移。

| 根任务独立检查 | 结果 |
| --- | --- |
| 完整Flutter | 最终701通过/4项隔离夹具默认skip；基线642，本批新增59。中断期间后台完成，日志15:52不作为性能依据 |
| Chrome复盘目录 | 最终91通过，16秒；旧33及本批新58，不含恢复面板那1项 |
| Analyze / Dart格式 | 最终无问题2.0秒；132文件0改动 |
| Node Web桥 | 58通过，无失败/skip |
| API / Ruff / metadata | 新独立库507通过107.44秒；连接目标30通过6.67秒；Ruff及73文件格式通过；alembic check无差异 |
| Web release | 最终默认本机API8000构建33.5秒；新浏览器验收8001构建32.9秒 |
| 完整字体 | 30,890映射/可变字重与源一致，WOFF2 7,782,072字节，最终包内中文与本地Roboto通过 |
| 本地文档 | 43份变更Markdown、353个本地链接/标题引用及围栏检查通过 |
| 实际Preview | 独立Previewer实际查看浅三项、深320/200%文字及blocked/有效空态；中文正常、可滚动阅读，无布局错误 |

API507是本批新增时间回归后的新证据；测试使用另建的`simontalk_review_page_20261021_test`，不清空浏览器fixture库或开发库。该库在metadata核对后已删除。本批真实浏览器走独立API与PostgreSQL测试库，不使用MockClient代替页面验收。

## 浏览器与隔离数据

临时API8001只绑定loopback/`simontalk_test`，三随机临时账号A/B/C；实际HTTP注册、偏好、准备、fixture-only信令、最终文字、end/manifest产生sealed来源。fixture信令不接真实网络媒体，保留unknown占用让现有current恢复入口可找到记录；不把它当可信终止证据。

A/C各3句、B无用户文字。review gateway初始blocked/0调用，后续模式仅由本机临时文件控制；有效建议解释明确标“界面验收夹具”。凭证只保存在0600临时文件，不提交或打印；模式文件不是产品接口，结果不证明语言质量或实际供应商费用。

实际浏览器结果：

- A从“查看未结束练习”→“查看保存状态”→“查看复盘”，初进后DB仍0个review input/job、0次gateway调用。明确整理为blocked/0次；切本机fixture能力后明确重试，页面先显示排队，再纯读刷新得到三项，三类标签/精确原话/建议/解释均可见。
- A三项可见时主动停止临时API，刷新撤下全部旧正文并说明登录仍保留；重启API后明确刷新恢复原结果，不创建额外尝试。
- B从本人直接地址进入，明确整理后为no_evaluable_content，无生成重试或gateway调用。C非法quote被整体拒绝为failed且不展示错误原话，明确重试有效空输出后为no_suggestions，文案没有声称表达无错。
- 初轮实际跨标签B登录轮换Cookie后，旧A刷新返回身份变化并清除原话；明确确认账号后显示B偏好，未展示A建议。最终重复这一流程时浏览器工具在B登录前后出现CDP调度超时，未把该次重复记为成功；最终账号恢复/来源隔离另由VM/Chrome回归覆盖。
- 最终新构建再次从真实A入口进入：地址确为`/#/practice/{sid}/review`，刷新保留同份结果，浏览器后退至account、前进回到同review并重新GET通过。320×568实际Tab/Enter刷新恢复后，焦点按钮完整可见；375宽原话/建议正常换行。初轮鼠标双击词、三击整句选择均有实际高亮，最终选择回归继续通过。

最终3个job、3个attempt、5个action、2个result；fixture gateway恰3次（success/invalid/empty），只读刷新/重新加载/前进返回没有新增生成。截图为明确测试内容：`/tmp/simontalk-review-page-final-375.png`及`/tmp/simontalk-review-page-final-320-focus.png`，不含密码或令牌。

三临时账号/邀请及所属数据均已删除并复核；临时API8001/Web7357、应用验收标签已关闭、视口恢复；0600凭证、fixture脚本/控制文件/pyc清理。默认API8000按最终后端重启，live/ready200。开发库head仍8b2731f5ca90、原17表数量完全未变（1用户/1邀请/11登录会话/1偏好，其余本轮相关数据均0），锁文件无改动。

随后独立启动`flutter widget-preview start --web-server --offline`，在实际Previewer筛选四项并查看浅/深、200%正文及空态。`previewWithFonts`加载成功，预览名称清楚标示“示例”，不访问账号/API；本机截图`/tmp/simontalk-review-page-preview-light-dark.png`。预览标签、CLI及其51365端口已关闭，未改Flutter SDK或引入依赖。

## 尚未覆盖

默认模型Unavailable；没有真实模型反馈、真实语音/手机设备/供应商终止与计量验证，没有完整对话/话轮跳转、一级重练、完整历史、用户删除或完整学习闭环。桌面浏览器/组件字号/语义检查不等于真实手机、Safari或辅助技术全体验验收。主动断开临时API的失败场景不解释此前预检后传输异常的未定原因。

本机非敏感日志：`/tmp/simontalk-review-page-{root-full,chrome,root-analyze,root-format,node,browser-build,web,api-full,connection-green,clock-red,metadata,fonts,preview}.log`。URL/焦点/账号历史的RED日志沿同前缀另存；日志和截图不含密码或访问令牌。
