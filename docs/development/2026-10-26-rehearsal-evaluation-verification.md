# 重练改善评价验证

日期：2026-10-26。按[计划](../superpowers/plans/2026-10-26-rehearsal-evaluation-and-qwen-control.md)落实既有一级重练的两轴评价；协议见[架构契约](../architecture/2026-10-26-rehearsal-evaluation.md)。本轮已完成后端、Flutter接入、真实固定样本、本人页面与组件预览；真实媒体边界仍单独保留。

## 后端与严格依据

复用现有输入绑定、ReviewJob/Attempt/Result和事务外worker，未新增表、依赖或迁移。普通结果线格式保留，旧重练缺评价仍可读；新重练有合格文字必须有评价，普通结果不得夹带。零建议而有有效评价为 succeeded。两轴分别绑定冻结目标及本次子用户精确引用，确定结论不接受空证据；来源在领取、外调前、写入前和读取时重核验。结果摘要覆盖新增字段，删除/租约/未知调用守卫保持。

首轮纯协议19、集成7、网关3项先RED；相关回归300通过/83.88秒。最后补入两型号MockHTTP→正式网关→worker→PG→本人GET组合后，新3文件48通过/21.44秒，包含GET全表零写。真实语义反馈后另补4项通用提示契约先RED，最终新旧网关及纯协议142通过/0.25秒。独立规格复核35通过/0.05秒，随后独立质量复核142通过/0.26秒，均未发现剩余确定问题；这些检查仅代表结构契约。

## 真实模型与失败保留

标准 create_app 显式 review_provider=qwen，通过生命周期runner访问真实 qwen3.8-flash；没有替换供应商返回正文。准备与封存使用独立测试数据库、测试准入及固定英文，不是实际媒体。父来源真实生成纠错，原句 `Yesterday I go to the park.`，后续目标均由服务器真实派生。

第一轮结构通过却语义失败：visited改写被判changed、另一条误称缺少“儿童”文本；第三子调用约7.27秒后结果未知，缺用量。见[首轮完整失败证据](evidence/2026-10-26-rehearsal-evaluation-first-live.json)。未知任务没有重试，仍只有1次尝试。不能把结构正确写成语言质量通过。

随后修正通用重练提示：明确 targets 是本次本人文字、冻结来源与当前表现分开、关键事实变化与语法修正分开、uncertain 不等于文字不存在；以不同的做饭/地点例子解释两轴。普通复盘提示未改，未针对实际park样本硬编码。

| 新配置样本 | 原意 | 目标问题 | 人工核对 |
| --- | --- | --- | --- |
| Yesterday I visited the park. | conveyed | demonstrated | 允许不同措辞；visited为过去式 |
| Yesterday I go to the park. | conveyed | still_present | 原意保留，原时态问题仍在 |
| Yesterday I went to the library. | changed | demonstrated | 地点变了，过去式正确，两轴独立 |
| Could you say that again? | insufficient_evidence | not_demonstrated | 没重述原事件、没展示目标，不等于失败或掌握 |

最后一类首次输出被本地校验判 invalid_output；未保留该次原始模型正文，不能声称已确定是哪一字段错误。随后按既有“已知失败”明确重试，第二次得到有效结果并逐项核对；不是自动重试，也没有重调未知任务。新配置最终四条引用均为各自本次原句精确子串。完整[真实结果/用量证据](evidence/2026-10-26-rehearsal-evaluation-live.json)保留首次失败及重试标记。

合计9次真实文字请求：1父、旧提示3子、新提示4子及1次已知失败重试；8任务/9尝试/7结果，6,796已知输入、1,445已知输出Token，另1次未知调用用量为null。页面纯读不会新增推理。按[该型号北京非缓存标价](https://help.aliyun.com/zh/model-studio/qwen3-8-flash)（输入0.8、输出2.7元/百万Token），本轮已知文字用量估约0.0093383元；另加新版实时已知0.002448元，合计已返回用量标价估约0.0117863元，未知调用和实际账单不在该数内。使用用户恢复的累计20元首轮预算，不能将已知Token当完整账单或硬停费证明。

## 客户端与实际页面

新增严格、深不可变Dart模型及两个评价卡片，保留普通/旧结果；按Unicode标量与UTF-8限制校验，并拒绝NUL、未配对surrogate、非规范UUID、额外字段和显式null。复用原SelectionArea、主题、680阅读宽度和账号/刷新撤旧门，不增加网络端口、评价定位接口或二级重练。

新增38项客户端测试；首轮29项中26项因缺失扩展解析RED，预览入口也先失败。复盘目录154通过/约7秒；最终全量 **Flutter1439通过、10项专用夹具skip（显示计时56秒）**，分析无问题/2.2秒、223文件格式0变化、Node58通过、Web release35.5秒与30,890完整字体映射通过。独立Flutter规格及质量复核均未发现剩余确定问题。

新release在桌面IAB 1280×720、同源loopback API、真实Cookie和独立PG17库读取刚生成的四条实际结果：

| 页面操作 | 实际验证 |
| --- | --- |
| 四类评价读取 | [同义改写](screenshots/browser-rehearsal-evaluation-conveyed.jpg)、[问题仍在](screenshots/browser-rehearsal-evaluation-still-present.jpg)、[原意变化/语法达到](screenshots/browser-rehearsal-evaluation-changed.jpg)、[证据不足/未展示](screenshots/browser-rehearsal-evaluation-not-demonstrated.jpg)均与SQL及精确引文一致；有建议的重练也没有二级派生按钮 |
| 读取故障/恢复 | 一次GET由临时测试中间件拒绝503，[两轴旧内容撤下](screenshots/browser-rehearsal-evaluation-read-failure.jpg)；明确刷新恢复原结果，不重新生成 |
| 查看本次文字 | 原入口进入[保存原文](screenshots/browser-rehearsal-evaluation-transcript.jpg)，显示该子的 Could you say that again?；返回恢复评价 |
| 跨标签换号 | 第二标签正常退出并登录另一账号，旧completion GET409后[两轴与来源清除](screenshots/browser-rehearsal-evaluation-account-changed.jpg)；重载后真实404，[无旧正文](screenshots/browser-rehearsal-evaluation-other-owner.jpg) |

共39条浏览器API元数据，38条真实API、1条测试503，未保存Cookie/Authorization/请求或响应正文。初次AX setValue未触发Flutter文字控制器，页面提示必填且零登录请求；改用键盘输入后实际登录200，不把工具输入问题记成账号故障。浏览器前后8任务/9尝试/7结果不变，原未知任务仍1次，新增推理0。[请求/产物证据](evidence/2026-10-26-rehearsal-evaluation-browser.json)。

实际Widget Previewer发现并渲染四项新增重练评价示例；[浅色两轴](screenshots/preview-rehearsal-evaluation-light.jpg)、[320深色200%意思卡](screenshots/preview-rehearsal-evaluation-dark320-200.jpg)及[目标卡](screenshots/preview-rehearsal-evaluation-dark320-target.jpg)可滚动、换行正常。明确点击刷新观察400毫秒撤旧/恢复，[本次文字弹窗](screenshots/preview-rehearsal-evaluation-interaction.jpg)已操作；这些均为独立fixture，不读取账号或调用业务API，不冒充真实模型页面。

## 最终回归与清理

最终后端全量在独立 `_test` 库执行：**1094通过/238.55秒，零skip**，强制配置PG17工具完成两项真实备份恢复。Ruff检查、99文件格式检查和38包离线锁检查通过。最终wheel的56个源码与当前源文件逐字一致、无私有Key或.env；在30包、无pytest的独立运行环境安装该wheel，56源码再核一致，默认关闭及纯构造Qwen网关检查通过。

开发21表全行摘要未变；3个本轮专属数据库、3个临时标签、API/Web与Previewer服务已清理，7357/55466端口不再监听。12张本轮截图均已查看。最终独立交叉审查PASS，未发现确定集成问题；私有配置及工作区保留核对见交接及[检查摘要](evidence/2026-10-26-rehearsal-evaluation-checks.json)。开工824文件全保留，16原文件有意更新、808摘要不变，新增29文件；10份Markdown/409本地链接、6份JSON、12张JPEG及私有Key扫描通过。日常配置仍默认disabled，未提交/推送/部署。

本轮固定英文样本不证明广泛语义、发音、长期能力或真实重练媒体质量；B2和B6仍需可信退出、精确播放截断与实际通话验收。新版控制实测另见[报告](2026-10-26-qwen38-control-verification.md)。供应商询问稿未发送，无提交/推送/部署或原生构建。
