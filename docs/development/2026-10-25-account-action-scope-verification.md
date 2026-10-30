# 设置与账号异步范围修补验证

日期：2026-10-25（Asia/Shanghai）。按连续开发授权推进不依赖模型输入的B1账号隔离缺口，先完成[设置点击计划](../superpowers/plans/2026-10-25-preferences-action-guards.md)，再继续[异步范围计划](../superpowers/plans/2026-10-25-account-async-scope.md)。契约见[设置动作与异步账号范围](../architecture/2026-10-25-account-action-scope.md)。

## 已复现与修补

1. 设置旧save在账号从A切B而页面未重建时仍PATCH；旧退出确认可注销B。先各观察真实controller+MockClient业务断言失败，再修补展示账号/偏好/草稿/provider/路由门。
2. 扩展62项首轮中36失败，其中10项是测试等待busy进度动画导致的pumpAndSettle超时，不能当产品缺陷；改有界pump。定位器首轮误匹配两处退出登录也已修正。正常路径及新增边界在最终目标通过，不宣称每个扩展用例都独立RED。
3. 第二组CSRF等待后发新身份请求、迟到save/logout成功/失败/401、冲突补读和销毁，12项全部先RED，再通过显式accountId和pending/ref.mounted门修补。
4. 独立静态复核提出网络异常清新凭据、清理完成覆盖API owner及自动恢复等待边界；补6项先RED，再修补repository清理前后身份门及_restore自己的pending。
5. 新门复核发现双恢复旧reply先返回会改共享身份，使最新恢复失败。null/A初态×两种顺序共4项，旧先回两项先RED；向repository传stillCurrent，身份写入前核同操作。最终独立静态复审无剩余确定问题。审查者未运行Flutter，运行证据均由主执行者执行。

生产限定三个文件：preferences_screen.dart、account_repository.dart、account_controller.dart。两个新测试文件89项页面+22项异步，共111项；账号目录原31项保留，最终目标142项通过（约7秒）。测试使用真实SimonTalkApp/go_router、AccountController和HTTP客户端，外部API为MockClient，未运行本轮真实后端/数据库或浏览器Cookie流程。

## 最终检查

| 检查 | 结果 |
| --- | --- |
| 全量Flutter | 1347 passed / 10专用夹具skip，44秒 |
| 分析/格式 | 无问题；218个Dart文件无格式变化 |
| Node传输 | 58通过/0失败 |
| Web release | release通过，34.5秒 |
| Web字体 | 完整30,890 Unicode映射、字形/字重及发布资产通过 |
| 独立复核 | 页面及异步两组只读静态复核；确定问题均复现修补后复审 |

没有布局、组件样式或预览注册变化；没有把旧截图/Preview或本机Widget测试标为本轮实际浏览器。初始设置正常保存、保存成功提示、正常退出确认、取消保留草稿、放弃返回、迟到成功不在新路由提示均有自动行为证据。原生已开始的安全存储删除不可撤回，未验真机并发I/O；登录/注册/重设整体竞态也不由此宣称完备。

## 工作区与边界

开工已有435个变更文件均保留，无丢失；仅设置页及HANDOFF/账号契约/交互/本地运行/验证五份原文档有意更新，其余开工已有文件摘要一致。账号controller/repository原为干净跟踪文件，本轮另有意修改。10份文档309个本地引用、围栏及Git空白检查通过；19个本轮私有日志/快照文件已清理。脱敏[执行与保留摘要](evidence/2026-10-25-account-action-scope.json)记录数量、代码摘要及验证边界，不含凭证或真实用户正文。依赖锁、后端、schema、开发数据均未改；没有后端/DB请求、模型、物理麦克风、原生构建、提交/推送/部署。前批后端921项是历史结果，本轮未重跑；B2真实退出/播放截断、B5真实反馈及B6继续受已暂缓条件约束。
