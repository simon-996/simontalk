# Android 构建与 Web 连接复查

日期：2026-10-16（Asia/Shanghai）。**最终结果：Android构建因磁盘不足失败，没有APK；用户随后要求暂停Android、删除本轮下载，后续以Flutter Web为主。清理已完成，仍处阶段2。** 早先“先生成APK，暂不连接设备”的指令已被新方向取代。

## 环境与范围

- Flutter 3.47.5 / Dart 3.13.4，Android Studio JBR 21.0.3；Android SDK API36、build-tools36.0.0、NDK28.2.13676358已存在。
- macOS arm64、16 GiB内存；磁盘可用空间随系统swap波动，观察到约686 MiB至5.1 GiB。没有清理用户SDK、全局缓存或其他项目。
- 未检测到连接的Android手机。本轮不启动模拟器、不安装、不代替接受SDK协议。
- 审阅后拒绝了唯一未接受的`microxr-sysimage-license`；未修改任何许可。普通手机构建尚未请求该模拟器组件。
- 尝试构建时，同一Gradle9.3.1临时改用bin分发并固定官方SHA-256，堆2GiB、最多2个worker；AGP9.1.0、Kotlin2.4.0不变。暂停后已撤回本轮Gradle配置改动，恢复先前提交的模板；这些调优没有通过完整APK验证。

## 构建证据

执行命令（`apps/client`）：

```sh
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
JAVA_TOOL_OPTIONS='-Dorg.gradle.daemon=false' \
flutter build apk --debug --target-platform android-arm64 \
  --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

首次执行停在Gradle分发下载校验，约898秒后退出1，尚未进入应用编译。预期SHA-256为`b266d5ff6b90eada6dc3b20cb090e3731302e553a27c5d3e4df1f0d76beaff06`，下载所得为`7e66959dee19d05e35b5ae67a5da446d1dd345609b595c2401872b1eca77af96`。Gradle拒绝该文件，没有关闭校验。

分别重读`services.gradle.org`与`downloads.gradle.org`的官方`.sha256`，结果与配置一致。独立curl下载经历DNS/连接超时，官方地址续传到80,904,839字节后停滞；最终通过[华为云公开镜像](https://repo.huaweicloud.com/gradle/gradle-9.3.1-bin.zip)补齐。完整文件137,037,885字节，SHA-256与上述官方值完全一致，`unzip -tq`通过，再放入本次新建的Wrapper缓存。仓库下载URL保持官方地址，未改用镜像配置。

第二次执行通过分发校验与解压，停在Flutter Gradle插件的Kotlin2.2.21依赖解析，错误为Maven Central的`Remote host terminated the handshake`；Flutter自动重试后仍退出1。独立Java21 HTTPS探测同一个POM：默认网络栈握手失败，`-Djava.net.preferIPv4Stack=true`返回200；curl也返回200。随后仅在本次构建命令增加该Java参数，未修改全局网络或TLS配置。原始下载校验失败的根因仍未确定。

启用IPv4的第三次执行进入Android构建与D8处理，约15分52秒后在`:app:mergeDebugNativeLibs`的Flutter arm64原生库提取阶段报`No space left on device`，同时出现无法写入日志和缓存的错误。当时磁盘仅剩约118MiB。Flutter自动重试约22.7秒，仍因同一磁盘错误退出1；最终没有APK。构建及其Gradle进程已退出，没有继续重试。

## 按用户新指令清理

先核对进程、目录创建时间与实际依赖坐标，再删除本轮新增的精确路径，未运行全局`flutter clean`或清空全局Gradle目录：

- Gradle9.3.1分发、该版本首次生成的缓存和daemon日志。
- 106个新建Maven版本目录，涵盖此次AGP9.1.0、Kotlin2.2.21/2.4.0及其Android/Flutter依赖；已有版本目录保留。
- 本项目Android构建中间产物、项目Gradle/Kotlin缓存和本次Android的Dart构建缓存。
- 本轮下载探测文件、已识别的临时下载文件，以及Flutter工具Gradle目录中本轮新建的9.3.1缓存；已有工具目录保留。

共清理约**1.789GiB实际分配的文件块**。清理后核对：Web的`main.dart.js`仍存在，原有Gradle8.14分发、Android API36 SDK仍存在，Android/iOS源码工程未删除。可用磁盘还会随系统swap变化，不能把前后`df`差值全部归因于此次清理。

CI中的APK构建步骤已移除，保留API检查与Flutter分析、测试、Web构建；Ruby Psych解析工作流YAML成功，尚未推送或运行远端CI。当前任务不再以APK或真机条件作为Web开发前置。

## 客户端自动检查

本轮重新运行`flutter analyze`，无问题；`flutter test --concurrency=1`共21项全部通过。没有客户端或后端业务代码变化，因此未重复后端测试；之前42项结果见账号基础验证记录。APK失败结果单独记录，分析与单元测试不能替代APK证据。

清理后重新执行`flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=http://127.0.0.1:8000`，约34.7秒编译成功。核对126个清理路径均不存在，`main.dart.js`仍有完整产物；本地Web HTTP200、API readiness返回`ok`。新建后台标签验证重建后的登录页正常显示，未捕获控制台warn/error，截图见[Web release登录页](screenshots/web-priority-login-release.jpg)；随后关闭临时标签，用户原标签未改动。

## Web复查

使用现有release产物和本地API，在应用内浏览器新建后台测试标签，保留用户原标签及输入。只使用本地联调账号：

1. 登录 → 偏好读取 → 退出；服务收到登录POST200、偏好GET200、退出POST204。
2. 不刷新页面再次登录 → 将英文字幕打开并保存；登录POST200、保存PATCH200。
3. 刷新后会话恢复，字幕设置仍开启；`/v1/me`与偏好GET均200。
4. 将字幕恢复原值并保存，页面显示“练习偏好已保存。”，PATCH200；再次退出POST204，回到登录页。

浏览器没有捕获到warn/error控制台记录。测试标签已关闭。截图：[保存后的偏好](screenshots/account-web-connection-recheck.jpg)。

本轮没有复现之前“预检成功、实际POST未到达”的传输异常，也没有足够证据确定旧异常根因。保留该待观察项；没有修改CORS、CSRF或会话逻辑，没有自动重放变更请求。一次复查通过不代表所有浏览器或真实大陆网络已验收。

## 交付限制

没有APK，未执行APK元数据或签名验收。原生安装、安全存储与音频验收已暂停；恢复需新任务安排。Web当前真实能力仍为账号与偏好，语音、复盘和学习记录未实现；远端CI和正式分发均未验证。本轮不推送、不部署、不调用付费模型。
