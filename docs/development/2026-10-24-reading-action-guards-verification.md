# 文字与关联列表阅读操作资格验证

日期：2026-10-24。按持续开发要求完成[计划](../superpowers/plans/2026-10-24-reading-action-guards.md)，复用已有生产控制器及仓库。

## 行为与复现

两个Screen点击时复验当前Route/最新URI、owner、账号busy和当前provider/controller；分页、原话定位与记录行绑定实际展示page。旧上一页不能从新页继续往前，旧下一页不能从新页继续往后；旧记录行即使在刷新结果中仍有同一ID，也不能跳转。当前有效操作和已有返回位置保留。

列表await返回及post-frame聚焦再核对当前页面、owner/provider、accepted page，覆盖页下迟到读取不会抢走其他页面焦点。账号busy保留原页、显示账号操作提示并禁用动作，不误称正在读取；返回仍允许实际请求中离页。旧重新连接在切页、busy或销毁后零restore，销毁后不读取WidgetRef。

新增42项回归全部先RED：文字20、关联22，包括busy/go/push旧操作、换页/刷新后旧回调、两页旧恢复和真实busy显示，以及覆盖后的迟到焦点。原两个Screen的23项测试仍通过。独立只读复核未发现确定缺陷。

## 实际验证

| 检查 | 实际结果 |
| --- | --- |
| 文字及重练目录目标 | 227通过，约7秒 |
| Flutter全量 | **1180通过，10项专用夹具默认skip，约33秒** |
| Node全量 | 58通过 |
| 静态/格式 | 修正3处括号规范后分析无问题/2.2秒，215个Dart文件格式符合 |
| Web release | 33.4秒；30,890映射、7,782,072字节WOFF2及本地Roboto检查通过 |
| 独立复核 | 无确定缺陷 |

未改Controller、Repository、HTTP/分页协议、后端/schema或依赖，未运行API/数据库或供应商调用；后端101文件及四个依赖文件保留。原改动保留，无原生构建、提交、推送、部署。[保留证据](evidence/2026-10-24-reading-action-guards-preservation.json)。

实际浏览器仍禁用；widget、Node和构建不代替真实Cookie/JavaScript、前进后退或Previewer验收。真实通话、结束补交、模型反馈与改善评价仍未完成。继续核对普通首页/准备页的路由切换操作资格；不反复索要已暂缓的模型/预算输入。
