# 一级重练来源与独立准备验证

日期：2026-10-22（Asia/Shanghai）。对应[设计](../superpowers/specs/2026-10-22-rehearsal-preparation-design.md)、[实施计划](../superpowers/plans/2026-10-22-rehearsal-preparation.md)与[实际契约](../architecture/2026-10-22-rehearsal-preparation.md)。本单元后端已完成，自动/真实HTTP/数据库证据与产品边界如下。

## 范围及审查

新增3个生产模块、2个测试文件和迁移1a6de74c9f20；修改PracticeSession、原普通准备共同构造/响应、router注册和POST接收门。目标来源纯读、确认hash后原子独立准备、固定目标读取及同级seek列表已实现；数据库强制同账号ordinary父及一级关系。

实施完成后先独立规格审通过，再独立质量审。质量审发现同级过滤/排序无适配索引的P2，核对成立后由原实施者补rehearsal_parent_seek部分索引及schema回归，质量复审通过，无剩余确定问题。没有引入新UI、模型/媒体、改善评价或用户删除接口。Flutter及依赖/锁文件不改，不把前批773/Chrome163当本轮重跑；保存文字实际浏览器/Preview点击仍因Work设置禁用待补。

## RED与自动检查

- 有真实sealed来源和本地worker有效建议的GET预期200而404，1项失败/0.56秒；来源接通后POST预期201而404。
- 固定快照先验结构缺口先失败后修复，不依靠当前父目标失败掩盖存储结构错误。
- 索引真实数据库/metadata回归先失败1项/0.29秒，补索引后1项/0.16秒。
- 初轮目标85项/36.82秒，实施者全量640项/159.49秒；root独立全量640项/153.49秒。
- 索引修补仅改model/迁移和schema测试，业务生产代码未改；最终目标86项/37.22秒。最终全量、Ruff与metadata结果见末节。

日志保留于`/tmp/simontalk-rehearsal-red.log`、`-create-red.log`、`-shape-red.log`、`-index-red.log`、`-index-targeted.log`、`-root-api.log`及`-index-full-api.log`。测试支持默认Unavailable、占用/unknown、CSRF/账号、精确来源/引用、损坏来源/快照、转义后大小、无建议、幂等/事务及同时间seek等边界。

## 独立真实HTTP

root专属库simontalk_rehearsal_20261022_test、API8001和A/B账号，注入本地反馈/admission夹具，实际供应商信令保持关闭。来源普通练习有两个连接，重复同一turn UUID：第一连接旧原话后被最新空修订覆盖；第二连接保存完整目标原话。另有AI旧修订已播prefix及未报告播放的新final后缀。

实际HTTP验证：

- text_only目标前文为空，conversation_context只保留安全旧prefix，不扩为新final；选中epoch2的完整用户原话和精确引用，canonical目标hash可复算。
- 来源目标GET前后13张内容业务表全行及夹具调用计数完全相同。
- 默认Unavailable创建503且无半条准备；隔离准入后201，保存独立kind/来源/目标与难度快照，不复制来源转写。
- 改偏好、关闭夹具准入后，同key仍返回完全相同原记录且不再次准入；改hash/item或改用于普通创建409。新key在占用时409。
- 安全取消第一子记录后，新key创建第二同级记录，使用当前偏好；第二条取消后，两页seek无重复，取消记录保留。
- 他人目标/子目标及跨父游标404，匿名401；子记录不能当普通来源派生。目标和列表纯读前后完整业务行及调用数不变。
- 刻意更改当前源result hash后，子目标409，但子记录GET与同级列表仍可读；两条子记录没有来源转写副本。

仅1次本地review夹具调用，创建2条独立重练；没有真实模型、音频或浏览器调用。证据：`/tmp/simontalk-rehearsal-http.log`及`-http-proof.json`。夹具返回的文字明确为接口验收样例，不能用来证明语言反馈质量。

## 迁移、约束与查询计划

root保留一条旧8b2731f5ca90普通记录，升级新版head、降旧head、再升级；原所有字段逐项相同，新字段ordinary/null，metadata匹配。实施者另有head→8b→head→base→head及4次metadata核验。存在真实两条重练时降级RuntimeError且head/记录未变。

专属库直接数据库验证：跨owner复合FK拒绝；以子为ordinary父的二次派生拒绝；单删第一子保留父及同级，删除普通父级联剩余真实子/文字，原review尝试仅保留无正文审计。此处仅验证数据库关系，不冒充删除产品流程或范围并发确认。

质量修补后root重做迁移/metadata及历史普通记录保留。另插入10,000条合成普通历史及40条同父子记录，在默认planner下执行EXPLAIN(ANALYZE,BUFFERS)：首屏及seek均使用rehearsal_parent_seek倒向索引读取，直接返回limit+1=11且无Sort，分别0.028/0.061毫秒；仅证明该隔离数据分布下的访问路径，不作生产性能承诺。合成行随后删除。初轮查询计划脚本曾因夹具creation_key类型及把游标辅助排序计入主查询而失败，修正夹具/分开游标读取后通过，没有改业务代码。

迁移证据`/tmp/simontalk-rehearsal-root-migration.log`、`-migration-proof.json`；约束`-root-db-boundaries.log`；索引`-index.log`、`-index-proof.json`和`-explain-first.json`/`-explain-seek.json`。

## 最终检查、开发库与清理

最终实施者全量641项通过/158.90秒；root独立最终目标86项通过/34.69秒（此前独立全量640项/153.49秒）。root Ruff check及82 Python格式通过，最终默认测试库head/metadata一致，19张测试业务表已清空。

默认开发库simontalk仅升级schema到1a6de74c9f20；原17项跟踪表计数全部不变，账号/邀请/登录会话原行逐项哈希未变，练习仍0条，metadata和新索引一致。API8000按最终代码重启，live/ready均200，四条新路径匿名均401，实际准入/信令/反馈三gateway均为Unavailable。

专属API8001已停止，simontalk_rehearsal_20261022_test整库已删除；A/B/legacy账号、邀请与所有测试正文随库清除。凭证、fixture控制文件、脚本及其pycache已清理；保留非敏感日志/JSON证明。没有新Web/Preview服务或浏览器标签，前批实际页面验收待补。

收尾证据`/tmp/simontalk-rehearsal-root-final-targeted.log`、`-dev-upgrade.log`、`-dev-proof.json`、`-default-api-proof.json`与`-cleanup-proof.json`。本地文档链接/围栏、git diff --check及锁文件无变化核验通过。没有提交、推送、部署或原生构建，全部原有dirty保留。下一单元接Flutter目标确认、独立准备读取及来源/同级导航，不把本次后端完成写成完整重练或学习闭环已完成。


计数口径校正：数据库metadata实际有19张业务表，另有alembic_version。历史“17表”基线只跟踪17张表，未包含password_reset_grants与rate_limit_buckets，不能据此称数据库总共17表。本轮保留17项既有计数对照，最终metadata核验覆盖全部19表；测试库清理覆盖全部19表，补充安全表当前计数见`/tmp/simontalk-rehearsal-final-db-proof.json`。首次收尾脚本把17误作metadata总数而主动断言中止，未执行TRUNCATE；核对后按19表安全清理，应用代码及验证结论不受影响。
