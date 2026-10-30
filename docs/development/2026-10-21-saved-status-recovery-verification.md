# 恢复入口保存与核验状态验证

日期：2026-10-21（Asia/Shanghai）。依据[设计](../superpowers/specs/2026-10-21-saved-status-recovery-design.md)、[实施计划](../superpowers/plans/2026-10-21-saved-status-recovery.md)与[当前接口](../architecture/2026-10-21-practice-finalization.md#7-恢复入口的保存与核验读取)。

## 本次交付

- 本人原连接的termination-check只读GET：单SQL left join，准确区分无任务not_requested与真实blocked/capability_unavailable/0次；无状态、租约、任务创建或供应商副作用，不返回attempt_digest。
- 严格Dart模型及仓库。global completion按最新结束来源校验；current返回较旧占用连接时，另GET实际origin独立确认account/session/client/epoch。核验任务仍绑定原占用连接，不把两种scope混为一谈。
- 恢复控制器明确读取、串行和一个八秒总截止，涵盖必要的两至三次GET；每次追加HTTP前复核身份与单调时间。两份展示快照原子发布，准确completion_not_found为尚未登记。刷新先清旧结果，网络失败保留登录，账号/401/409/父404/总刷新/dispose清旧数据，晚响应不恢复。
- 已确认登记结束的无正文endRegistered门保留到总current刷新或作用域清理；第二GET或后续局部刷新失败不重新放行旧准备清理。页面按钮、确认入口和控制器均受此门约束。
- 真实偏好页增加“保存状态”，显示未查询、读取中、未登记、等待封存、完整或缺口及明确读取失败/重试。ending使用实际固定截止并等待封存，不声称截止后仍收内容。缺口按可理解原因合并，sealed不能靠刷新补回。连接/用量单独说明，只有实际blocked才提示需维护者协助。
- completed显示“上次练习状态/练习已结束”；已有最终文字的分页、选择与滚动保留。所有新增查看/刷新只GET，不结束、上传、接管媒体或解锁unknown占用。

## 实际HTTP与浏览器

临时API8000仅使用独立`simontalk_test`和测试准入，未连接供应商。A通过真实创建/连接/end/空manifest接口形成sealed/incomplete；unknown信令尝试元数据为明确数据库测试夹具，不是真实上游连接。B为真实接口登记的preparing/not_started准备，测试库中暂延长其租约以稳定浏览器验收。默认开发库未写入假练习。

`test/integration/saved_status_wire_test.dart`以真实Dart http.Client、ApiClient和恢复控制器连接FastAPI/PostgreSQL，**1项通过**：

1. A明确读取后得到sealed、incomplete、tail_unconfirmed及真实blocked/0次，连接termination仍unknown；只读刷新不改变原租约。
2. B准确completion_not_found被显示模型判为未登记；核验记录not_requested，身份与B原连接一致。
3. B访问A的termination-check为404；客户端身份变化立即清A摘要、核验快照与已知end门。

实际发布Web包在本机7357访问测试API：

- A通过真实Web Cookie登录，在偏好页点击current后仍未自动查询保存状态；再点击“查看保存状态”显示已有内容仍有缺口、最后话语可能未完成识别及需维护者确认。没有新练习或强制释放入口。
- 主动停止本轮测试API后点击“刷新保存状态”，旧摘要和blocked说明消失，显示读取失败和“重试读取保存状态”；重启同测试API后明确重试恢复真实结果，登录未被清除。
- 在375和320宽度检查换行与按钮，375实际Tab可到保存刷新按钮并有焦点底色，Enter可触发读取。320无水平截断；截图保留为本轮本机产物`/tmp/simontalk-saved-status-375.jpg`。
- A退出后登录B，旧摘要不出现。B明确读取结果为“尚未登记结束保存/尚未开始远端媒体”，没有A的缺口或blocked说明。B随后退出。

Flutter Preview新增保存状态浅色、深色完整和320宽深色大字号三份预览；本次实际查看浅色缺口及深色两倍字号卡片，中文、原因、按钮自然换行。Widget测试另覆盖两主题320/375/900宽两倍字号、三份真实预览函数渲染、键盘激活及48以上触达目标。桌面视口与组件测试不代表真实手机或屏幕阅读器已验收。

## 检查结果

| 检查 | 实际结果 |
| --- | --- |
| API全量 | **394通过，70.88秒**；新只读接口7项，包含隔离、no-store、读取前后不变、撤销登录及账号头 |
| Flutter全量 | **609通过，3项隔离夹具默认跳过**；约19秒 |
| lint修正后相关回归 | **42通过**；本轮只补测试格式/等价null-aware写法 |
| 独立实际HTTP | **1通过**，非MockClient；上述新fixture用例 |
| Node/Web桥接 | **58通过**，1058.7毫秒 |
| Flutter分析 | **无问题，2.3秒** |
| Dart格式 | **111个文件，0变更** |
| Ruff检查/格式 | **通过，61个Python文件已格式化** |
| Web发布构建 | **通过，最终37.4秒**，release/no-pub/no-web-resources-cdn |
| 字体 | **30,890 Unicode映射完整**；压缩字体7,782,072字节，发布包含核验字体和本地Roboto |
| Git与依赖 | diff空白检查及26份变更Markdown的238处本地文件/标题链接通过，pubspec.lock/uv.lock无变化；未新增迁移 |
| 开发服务 | 默认关闭准入/网关的API8000已恢复，live/ready均200 |

目标测试首先因缺接口、模型和控制器/组件端口失败，之后实现通过。中途修正预览/测试误用非const factory，以及preview样例缺口排序；独立审查还发现ending截止后文案及旧准备清理重新放行问题，均补回归后复审通过。首次Preview离线启动使用了不匹配的缓存来源；按既有镜像配置运行官方clean并重新启动成功，无SDK修改或依赖升级。首次Node命令未带Flutter可执行路径，修正PATH后完整58项通过；这些启动环境失败不计作功能RED。

规格审查通过后再独立质量审查，最终无剩余确定问题；质量审查包含有效摘要已返回但第二GET失败仍阻止过期清理的门。审查为只读，未与真实fixture并发操作数据库。

日志本机保留：`/tmp/simontalk-saved-{api-full,flutter-full,node,analyze,format,web,fonts,wire,lint-regression}.log`；目标/初始RED与Preview日志另以saved-status、saved-recovery、saved-view、saved-preview前缀保留。日志和截图不含访问令牌或密码。

## 清理与边界

真实测试两账号/邀请码及关联认证、偏好、练习、连接、completion/member/核验均精确删除核对；凭证夹具、临时准入脚本、seed脚本及对应pyc已移除。Web/Preview/测试API已关闭，预览生成目录经官方clean清理，浏览器两标签关闭且视口恢复。首次清理核对误用了核验表不存在的user_id列，事务完整回滚；按实际connection_id再次核对并成功完成，没有遗留临时身份。

开发库保持head **0e1874613efa**，原1用户、1邀请、11认证会话、1偏好；练习、连接、观测、两账本、completion/member及核验均0。本轮只读接口无需迁移，既有未提交工作全部保留；未提交、推送、部署、原生构建或调用模型。

当前入口受current范围限制，安全结束后current为空的练习仍缺完整历史；正式通话/结束保存页、实际语音/设备对齐、可执行可信终止、完整复盘输入资格、反馈/一级重练/删除与用量控制仍未完成。下一单元推进完整复盘输入资格，供应商账号/预算/设备输入继续暂缓。
