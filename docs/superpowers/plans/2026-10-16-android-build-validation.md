# Android 构建尝试与 Web 优先调整

> **For agentic workers:** 按既有账号基础计划继续执行；构建采用实际命令验证，行为修复遵循 systematic-debugging 与 test-driven-development。步骤逐项记录。

**当前状态：** Android因磁盘不足构建失败。用户随后明确暂停Android、删除本轮下载，后续以Flutter Web为主。APK产出与签名检查已取消；以下保留实际执行记录，新增清理与Web验证任务。

**Goal:** 完成本轮新增Android下载及中间产物清理，保留Web功能，同步Web优先方向和验证证据。

**Architecture:** 延续Flutter 3.47.5与现有账号API，以Web推进；Android/iOS源码保留，暂停原生构建。早先仅生成APK的授权已被最新用户指令取代。

**Tech Stack:** Dart 3.13.4、Java21、Android API36/min24、FastAPI/PostgreSQL。

## Task 1：构建条件与配置

- [x] 读取HANDOFF/AGENTS、检查Git、磁盘、Java、SDK、缓存、设备；工作目录和功能分支不变。
- [x] SDK许可只审阅不接受：缺少的是microXR模拟器许可，与当前普通Android构建无关。
- [x] 尝试同版本bin分发与官方SHA256；暂停后撤回该配置，未通过完整APK验证。
- [x] 尝试Gradle堆2GiB、最多2个worker；暂停后撤回该配置，未改全局配置。
- [x] 实际构建推进到原生库合并，因磁盘不足失败退出；错误阶段已记录。没有下载模拟器或升级SDK。

```sh
cd apps/client
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' flutter build apk --debug --target-platform android-arm64 --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

首包面向常见arm64真机，使用adb reverse访问本机API；没有设备时不声称完成安装验收。网络、版本或SDK缺项先定位，再做最小必要修复，不因缓存里已有其他版本就盲目降级。

## Task 2：产物与自动检查

- [ ] **已取消：** APK不存在，不进行签名、元数据或安装验收。
- [ ] 相关配置变更以真实构建为检查，不编写仅重复配置文本的测试；业务代码变化先加入可失败回归。
- [x] Flutter analyze无问题，21项Flutter测试通过；不将debug APK视为正式分发签名或真机成功。

## Task 3：Web遗留排查与交接

- [x] 检查当前API/Web服务，尝试复现之前“OPTIONS200、POST未到达”的情况；本轮独立标签两次登录/退出、两次偏好保存与刷新恢复均成功，服务收到实际POST/PATCH，未复现旧异常。
- [x] 没有确定旧异常根因；记录为本轮未复现，不修改鉴权、不自动重放请求、不宣称问题修复。
- [x] 更新HANDOFF、运行说明、产品/工程决策、路线与验证计划和本批验证记录；保存在本地功能分支，不推送、不部署、不调用付费模型。

## Task 4：Web优先与资源清理

- [x] 确认构建进程已退出，精确清理本轮新增Gradle、106个Maven版本目录、Android中间产物和临时下载；约1.789GiB。
- [x] 保留Web产物、原有SDK与缓存、Android/iOS源码；撤回本轮未验证完成的Gradle配置改动。
- [x] 移除CI中的APK构建步骤，保留Web/API检查；不擅自推送。
- [x] 清理后Web release重新构建成功，本地Web/API正常；登录页面显示正常，已保存截图，记录结果。

## 安全与范围

不代替用户接受SDK协议；按用户明确要求清理本轮新增下载，不删除此前SDK、Gradle或其他项目。本轮不启动模拟器、不连接真机、不产生模型费用。恢复原生构建前重新核对最新用户方向和环境。

参考：[Gradle Wrapper官方说明](https://docs.gradle.org/current/userguide/gradle_wrapper.html)，二进制分发及校验信息由Gradle官方服务读取。
