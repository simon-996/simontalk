# RTC恢复与Web打断：公开契约补查

2026-10-26（Asia/Shanghai）。沿用用户“先只查公开资料”，完成两组核查：任务恢复/退出证据，以及Web打断接口。没有提交工单、登录控制台、调用RTC业务API或模型；没有选用RTC、修改应用/依赖或访问数据库。

## 任务恢复：新增的正向证据与未获保证

[RTC回调文档](https://help.aliyun.com/zh/document_detail/2709168.html)定义4002智能体退出事件，含channelId、taskId和发生时间。签名按原始请求体及时间戳，用回调密钥做HMAC-SHA256；信封还有eventId。文档明确重复、乱序和有限次重试，因此缺失回调不能作为退出证据。

这是候选退出证据来源，仍需绑定原App/Channel/Task及唯一attempt、验签与持久去重后验证实际语义；不代表本项目已接通，更不等于费用已结清。普通用户离会、内部错误、静默通知与智能体退出不能混作同一个终态。

通过[官方说明的免鉴权元数据入口](https://help.aliyun.com/zh/sdk/product-overview/openapi-metadata)，实际GET三份公开JSON，均200。此操作只下载接口定义，不启动/查询/停止任何用户任务，不证明账号权限。

| 本轮核对 | 发现 | 对后续实现的限制 |
| --- | --- | --- |
| [StartAgent元数据](https://api.aliyun.com/meta/v1/products/rtc/versions/2018-01-11/apis/StartAgent/api.json) | caller TaskId与App/Channel为请求字段，成功仅RequestId；所查定义没有errorCodes字段或重复创建保证 | 有TaskId不等于幂等；不能默认自动重发创建 |
| [GetAgent元数据](https://api.aliyun.com/meta/v1/products/rtc/versions/2018-01-11/apis/GetAgent/api.json) | 状态、开始/结束时间定义为字符串；未给查无对象/终态保留规则 | 不把未启动、404、失败或缺字段归为“肯定没启动”；需核原attempt的正向证据 |
| [StopAgent元数据](https://api.aliyun.com/meta/v1/products/rtc/versions/2018-01-11/apis/StopAgent/api.json) | 成功仅RequestId，未定义终态确认 | 受理后仍需查询或可验证退出证据 |
| 三份元数据的synchronous标注 | 标注接口请求返回方式 | 不能将它解释为智能体已同步启动/结束 |
| 所查错误中心页面 | 本轮文本读取仅得空壳，没有错误码正文 | 不编造不存在、重复TaskId或安全重试的具体错误码 |

另固定[官方Python RTC SDK](https://github.com/aliyun/alibabacloud-python-sdk/blob/a26edd9f0f9b5797fa9270b23b7a01382c5a3b29/rtc-20180111/alibabacloud_rtc20180111/client.py#L9090)提交`a26edd9f0f9b5797fa9270b23b7a01382c5a3b29`，读取client及四份模型文件。RPC/AK鉴权与请求字段一致；Start/Stop模型只有RequestId。Get模型from_map直接接收字段，未做类型转换，不能靠SDK注解证明实际wire类型。默认RuntimeOptions的存在也不证明已关闭底层重试。没有安装或执行SDK。

### 工程推导，尚未实施或实测

缺创建幂等不必直接否定整条路线：可以考虑外调前保存唯一TaskId、永不复用，创建只发送一次，结果不明后只核原任务；SDK、代理和调用层都不能悄悄重发。它是一条待验证方案，不是已得到供应商承诺。

| 情形 | 候选处理与验收要求 |
| --- | --- |
| Start回包丢失，首次Get为未启动/不存在，随后原创建迟到 | 保留unknown，不能改ID再Start；需验证之后能定位到原任务 |
| Stop受理后仍为正在停止 | 继续有界核验，不能凭RequestId解锁；核验耗尽后进入需维护状态 |
| 原attempt收到可信终态查询/验签退出事件 | 核对身份、时间与终态含义，持久记录；迟到启动/运行通知不能回退已证实终态 |
| 回调丢失、重复、乱序或接收端停机 | 重复处理幂等；不能以沉默证明结束；查询保留期及恢复策略仍需核实 |

该推导依赖正向终态证据，不承诺任何查无对象都可释放。终态保留、迟到创建、原任务的退出是否排除后续处理与计费仍未实测；没有公开资料支持时不填一个本地超时值作为上游保证。

## Web打断接口核对

[官方Web接入页](https://help.aliyun.com/zh/document_detail/2978394.html)使用dingrtc与dingrtc-aiagent，暴露转录/状态事件和interrupt。按该包名读取[公开npm元数据](https://registry.npmjs.org/dingrtc-aiagent/latest)，本轮解析版本1.0.10，并按registry的SHA512 integrity核对tarball；只读取package.json及完整index.d.ts，没有安装、导入或执行JavaScript。

公开类型中interrupt返回void；AIAgentMessage只有message、uid、reasoning、userType、extra、end。所查公开类型未定义设备已播音频时刻、精确文字前缀或上游上下文截断确认。类型声明的状态为thinking，文档例子写processing，接入时也须核对实际版本与事件。以上只限定所查文档/类型，不断言服务端或其他版本绝无相应能力。

因此“SDK能打断”不能直接接入SimonTalk的confirmContextTruncated或verified output position；文本end标记也没有被验成设备播放完成。RTC的退出控制与插话上下文是两项独立验收，补上回调不自动补齐后者。

## 结果与边界

[证据JSON](evidence/2026-10-26-rtc-recovery-public.json)保留3份公开元数据的原响应摘要、固定SDK来源及Web包完整性/类型摘要。新增退出回调候选和单发核验推导，收窄了可走路线；重复/迟到创建、终态保留、真实退出/计费、精确播放上下文与Flutter Web实测仍缺。正式Omni准入保持关闭，RTC未选用，B2/B6不标完成。

已核查的公开入口没有补齐剩余承诺。后续应围绕新的官方明确说明或另行授权的针对性实测推进；不再重复相同关键词检索或把更多缺失报告当作开发完成。工单仍不发送，原生/提交/推送/部署保持暂停。无应用代码变化，不重跑历史测试/构建。

开工822文件保留；4份原文档有意更新、818摘要不变，新增本报告及JSON。私有.env摘要未变/0600，临时元数据、包内容和核验文件已清理；本地引用、JSON、密钥隔离和Git空白检查通过。没有访问开发或测试数据库。
