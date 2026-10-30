# 播放与冻结前缀证据持久化验证

日期：2026-10-21（Asia/Shanghai）。依据[设计](../superpowers/specs/2026-10-21-playback-evidence-design.md)、[实施计划](../superpowers/plans/2026-10-21-playback-evidence.md)和[接口契约](../architecture/2026-10-21-playback-evidence.md)。

## 实际交付

- 新增原账号、练习、连接、client instance及epoch绑定的独立`playback-evidence`追加/分页接口和数据库子表。alignment、首次freeze、永久revoke保留原文字/播放版本、来源和停止边界；精确重放不增加记录、不改接收时间。与最终文字双向核验身份、映射、同版本正文和final单调性，在共享连接锁内提交。
- 普通事件512条、撤销独立256槽、turn/response各256、正文累计2MiB。请求按实际分块限制512KiB/5秒；读取每页最多16。撤销可以先到作保守墓碑，普通额度耗尽后仍可撤销；父对象删除级联清理。保存不会续租、改终止或释放占用，未开始准备仍按可信连接完整历史清理。
- 客户端实现严格自含版本事件、不可变账本/跨页重建和独立确认队列。每批4条，普通pending64条/256KiB，撤销预留独立槽；原ID/sequence稳定，8秒总截止包含CSRF，失败暂停并显式重试。finish继续排队，abort取消旧请求并同步清正文，确认完成释放内部正文。
- 媒体协调器仅采集投影已应用的播放/首次freeze/撤销；freeze取修改投影前的原turn，晚final不改旧前缀，撤销先入队再安全停止。账号provider同时持有文字和播放两个队列，任一pending时保留，关闭且全部确认后释放。新增仓库只读GET，无媒体或创建副作用。
- 保留各response已应用播放的历史最大位置。新文字使当前播放重置unknown后，正常end的fallback停止边界仍覆盖历史位置；显式协议边界与历史矛盾时拒绝，有效值保持原报告。

## 实际HTTP与数据库

独立loopback API使用`simontalk_test`，仅临时进程注入测试准入；信令网关仍Unavailable，没有供应商调用。实际Dart `http.Client`、ApiClient、两个真实journal和PracticeRepository连接FastAPI/PostgreSQL，未使用MockClient：

1. A账号提交r1 partial（Hello、400ms）及原版本freeze；独立最终文字journal提交r2 final，再提交r2的独立播放对齐。
2. 每页1条读取三条证据，最新来源为r2、冻结前缀仍绑定r1；新final不继承旧播放。后续revoke以新页到达，使新history前缀失效，旧不可变history保持原值。
3. 原event精确POST重放后仍为4条、last_sequence=4，received_at不变。B读取A连接404，读取自己连接为空；原transcripts的AI delivery_status仍unknown。
4. 连接完整GET结果前后一致，包含租约、状态和终止。数据库直接核对alignment→freeze→alignment→revoke共4条，最终文字1条，随后精确删除两测试账号/邀请码及级联数据，确认关联记录为0。

实际链路测试**1项通过**，日志`/tmp/simontalk-playback-wire.log`。测试文件需要外部隔离夹具路径`SIMONTALK_PLAYBACK_WIRE_FIXTURE`；全量Flutter默认明确跳过这一项，不把跳过算通过。临时凭证文件、种子/清理脚本、测试API及8001监听已清理；没有往开发库造练习。

## 最终检查

| 检查 | 实际结果 |
| --- | --- |
| API全套 | **344项通过**，61.79秒；前批276，本批新增68 |
| Ruff | check通过，55文件格式无变化 |
| Alembic | head `d41a7c9e2b60`；独立测试库降到b97d2a641e30后升回head通过，表消失/重建及metadata check无差异 |
| 开发库 | 从b97d2a641e30升级；原用户1、邀请1、登录会话11、偏好1及练习/连接/观测/文字0数量保持；新播放表0 |
| 开发API | 已重启新源码；`/health/live`、`/health/ready`均200；新路由未登录401；默认准入/信令网关仍Unavailable |
| Flutter完整测试 | **534项通过、1项明确跳过**，约16秒；前批494，本批新增40 |
| 独立实际HTTP | **1项通过**，不计入上述默认跳过项 |
| Node传输/启动/实际Dart桥 | **58项通过**，约0.65秒 |
| Flutter分析/格式 | 无问题，2.3秒；97个Dart文件，0更改 |
| Web release | **40.8秒通过**，no-pub、no-web-resources-cdn，API为127.0.0.1:8000 |
| 发布字体 | 完整30,890 Unicode映射；WOFF2 7,782,072字节；发布文件与本地中文/Roboto一致 |
| 依赖 | pubspec.lock、uv.lock无差异，无依赖升级 |
| 文档与空白 | 19份Markdown、181处本地链接/标题锚点及围栏通过；git diff --check通过 |

本机全套日志：`/tmp/simontalk-playback-api-full.log`、`/tmp/simontalk-playback-flutter-full.log`、`/tmp/simontalk-playback-node.log`、`/tmp/simontalk-playback-web-build.log`和`/tmp/simontalk-playback-fonts.log`。Wasm dry run不是Wasm或原生验收。

## 失败回归与独立审查

后端先运行缺失接口失败用例，客户端先运行缺少模型/journal端口及媒体记录行为的失败用例，再实现。跨账本修订回退、首次freeze历史位置和成员约束在规格审查后补回归并修复。最终规格复审发现：r1已播400ms、r2 final重置unknown后end fallback错误推导0；新增用例先实际失败，再维护历史最大位置。另覆盖显式399矛盾拒绝、显式550保留、stale旧来源900不污染历史；局部60项通过后全套复验。

最终独立质量审查核对后端原子追加/锁序、精确重放/撤销容量、双向版本校验，以及客户端ACK、总截止、账号取消、分页和两队列保留，未发现剩余确定问题。审查没有替代root的真实HTTP或全套运行证据。

## 边界与下一步

这是`client_reported`申报账本，`device_output_aligned`仍由测试适配器提供，未证明物理设备输出、用户听见或供应商对齐。未封存分页固定`sealed=false/recoverable=false`，不自动重建可用媒体上下文。未接播放记录UI；现有只读最终文字继续显示AI播放unknown。

实际准入、供应商网关和归一化协议继续关闭，没有付费调用、物理设备、可信终止或费用封顶证据。下一单元实现服务端结束受理、固定补交截止、固化水位与覆盖/缺口；需同时约束文字及播放接口，不能把客户端水位当已收到，不能把本地关闭当上游终止。正式练习/保存页、反馈与一级重练仍缺，原生暂停。

工作保留在`feat/account-foundation`，原有未提交文档/客户端改动完整保留。本单元未提交、推送或部署。
