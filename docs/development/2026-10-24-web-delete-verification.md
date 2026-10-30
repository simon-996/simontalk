# Web 删除预检与账号绑定验证

日期：2026-10-24。按[基础版本路线](../superpowers/plans/2026-10-22-basic-version-development.md)核对B1/B3/B4验收，修补实际发现的两处DELETE遗漏。没有新增页面、供应商适配、数据库结构或依赖。

## 问题与修补

删除接口已使用DELETE，但应用CORS只允许GET/POST/PATCH/OPTIONS。真实create_app中间件回归复现：来自两个默认Web来源的合法删除预检均返回400，浏览器无法继续实际请求。CORS明确加入DELETE，精确来源、凭证与请求头白名单保持原规则；非法方法的旧错误格式测试改用仍未开放的PUT。

继续核对实际Cookie删除发现，session_identity只对Web POST/PATCH强制X-Account-ID。新增回归复现缺失账号头时错误返回200并完成删除。将DELETE纳入同一账号绑定规则：缺失/不匹配均409 account_changed，不执行删除；Origin/CSRF和锁后身份复验保持原约束。客户端本来已发送该头，本轮无需修改Flutter。

## 实际验证

| 检查 | 结果 |
| --- | --- |
| CORS RED | 2个合法来源预检失败（400，预期200）；3项非法来源/方法/请求头拒绝原已满足 |
| 账号绑定RED | 6项凭证拒绝中，缺X-Account-ID返回200而非409；其余5项原已满足 |
| 修补后目标回归 | **66通过，12.17秒**：CORS、删除、错误边界、运行约束及账号 |
| 后端全量 | **720通过，183.76秒**；本轮新增11项常规回归 |
| Ruff/格式 | 全API检查通过，**96个Python文件**格式符合（含迁移） |
| 独立只读复核 | 两处生产改动及真实中间件/删除回归未发现确定缺陷；未另行访问数据库 |
| 开发数据保留 | 只读前后对比，20业务表及alembic_version全行摘要一致，head仍4f6a58cd2e32 |
| 清理 | 专属测试数据库已删除，无启动的API/Web服务；本地提交、推送、部署均未执行 |

新增5项CORS测试实际调用应用中间件，不启动lifespan；数据库URL指向不可用测试端口，并由SQLAlchemy do_connect监听器硬拒连接，确认预检完全不查库、不要求登录。覆盖两默认loopback来源，以及伪造来源、PUT、非法头的拒绝和安全错误格式。默认允许两个主机的Origin，不代表浏览器可以混用这两个主机的Cookie；本地Web/API仍须使用相同主机名。

新增6项Cookie删除测试覆盖缺Origin、陌生Origin、缺/错CSRF和缺/错账号绑定；每次拒绝后逐表全行比较一致。既有Web成功测试现覆盖预检→带合法Cookie/CSRF/账号头删除→原key返回原凭据→旧详情404，并检查实际响应CORS凭证头。全量测试继续覆盖父子范围、跨账号、unknown占用、晚到任务、恢复及其他写操作。

数据库测试使用本轮新建的独立`_test`库，两个环境变量均指向它，避免测试中默认create_app或CLI访问开发库。[开发数据证据](evidence/2026-10-24-web-delete-database.json)仅含数量/一致性结果，不含账号或正文；[工作区保留证据](evidence/2026-10-24-web-delete-preservation.json)记录本轮实际变更，原有工作保留。

## 验收边界与后续

当前[B1–B6验收矩阵](../validation/2026-10-15-validation-plan.md#22-当前验收矩阵2026-10-24)列明工程证据与缺项。720项是服务端测试结果，TestClient不会执行浏览器的Cookie/SameSite策略或JavaScript，不将本轮回归写成实际浏览器验收。浏览器工具本轮仍明确提示“Local browser use is disabled in Work settings”，未执行页面点击或新增截图。

Flutter、Node、Web产物及锁文件均未改，本轮没有重复构建或引用旧结果充作新验证。真实语音、真实反馈、完整B6、供应商可信终止/用量、实际设备网络仍未完成；模型输入继续按用户安排暂缓。没有模型调用、原生构建、自动备份或正式交付。
