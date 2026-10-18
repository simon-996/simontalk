# Recovery Browser Failure Verification Plan

> 使用superpowers:executing-plans执行本地验收；发现确定缺陷时按systematic-debugging/test-driven-development先复现再修复，完成后按requesting-code-review复核。沿持续授权直接推进，不推送、部署、构建原生或调用供应商。

**Goal:** 用真实Flutter Web、Cookie和API证明恢复入口在断连、写入结果未知和跨标签账号变化时保持身份与状态边界。

**Architecture:** 发布包沿用当前a6b7eab；临时localhost:7358/8001服务只连接simontalk_test，测试准入和可控延迟只存在临时夹具。生产代码仅针对实际复现的问题修改。

**Tech Stack:** Flutter Web release、IAB、FastAPI/PostgreSQL17；真实HTTP/Origin/CSRF，无新产品依赖。

## Task 1: 核对与夹具

- [x] 完整阅读HANDOFF并核对干净分支和a6b7eab；读取恢复控制器、账号仓库/控制器和服务端身份规则，无CodeGraph目录。
- [x] 创建独立测试账号A/B，各自非空准备；正常API设置偏好，默认网关保持Unavailable。临时文件只保存本批清理所需ID/摘要，不输出业务凭证。
- [x] 启动对应release静态服务与临时API，记录关键方法/路径/状态码，不记录密码、Cookie或CSRF值。

## Task 2: 真实浏览器验收

- [x] A正常登录并加载current；停止临时API后明确刷新，验证网络失败、旧快照/操作入口清除、账号仍保留；重启后只有本人点击才重查并恢复。
- [x] 服务端真实提交A准备清理后延迟响应超过8秒；验证未确认提示、无自动重放/读取，数据库取消已落地；明确刷新后确认空current，POST总数仍为1。
- [x] 重建A准备，旧页面打开确认；另一标签正常退出A、登录B，再由A页面确认。旧写操作403、后续GET409；A/B准备均不变；明确确认后显示B，无旧POST重放。
- [x] 共享会话退出后401清空恢复数据，明确确认回登录；与网络失败分开记录。未发现确定缺陷，无业务代码修复或新失败回归。

## Task 3: 交接

- [x] 关闭本批浏览器/临时服务，按保存ID和邀请码摘要清理2账号/2邀请；开发库只读核对1账号/0练习/0连接/0观测不变。
- [x] 本批没有业务代码改动，自动检查明确沿用a6b7eab，未宣称重跑。独立只读证据审查确认请求/截图与现有代码一致，自动行为表述限于观察窗口；文档链接、JSON结构、图片实际格式及git diff已检查，更新交接并本地提交。

实际步骤和证据见[验收记录](../../development/2026-10-18-recovery-browser-failures-verification.md)。
