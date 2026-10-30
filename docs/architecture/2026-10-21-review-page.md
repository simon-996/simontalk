# 复盘入口与阅读页面

日期：2026-10-21。实现范围见[页面设计](../superpowers/specs/2026-10-21-review-page-design.md)，任务请求、固定动作和结果验证沿用[复盘客户端契约](2026-10-21-review-client.md)。本页只描述客户端组合，不改变后端或模型准入。

## 来源与生命周期

路由为`/practice/:sessionId/review`，地址只含练习UUID。入口来自恢复面板当前读到的本人sealed摘要；点击时重新核对当前账号、摘要和busy。直接打开网址也必须重新GET本人`/v1/practice-sessions/{sessionId}/completion`，不依赖会随刷新丢失的路由extra。

`ReviewPageController`持有原账号和练习ID，以独立ApiClient fork读取来源。只接受原账号/原练习、server_recorded来源、有效origin连接/client/epoch及严格`PracticeCompletionSummary`；sealed才由既有factory建立`ReviewTarget`。构造零请求，来源阶段总8秒，后续任务纯读另受原客户端8秒限制，属于两个连续有界阶段。

外层操作单飞；来源读取期间撤下旧显示，相同target保留子客户端及不确定动作，不能因刷新换key。来源网络失败时不能显示旧结果或生成，但可在重新确认同来源后继续明确确认原动作；来源缺失、非法或身份失效销毁子客户端。账号getter及dispose清理内容、关闭原fork/子客户端，迟到结果不能发布或发出下一步。

## 读取、写入与导航

页面初次进入仅做一次来源GET和现有任务GET；不自动创建、轮询或生成重试。整理表达建议、确认上次整理请求和允许时重试整理分别调用原客户端的`requestReview`、`retryPending`和`retryGeneration`；纯读按钮调用`refresh`。确定冲突后的needsRead门、未知调用和三次上限不由页面放宽。

已登录账号可进入页面；恢复账号和网络待确认时保留review地址但不读练习内容。无效UUID零HTTP。未登录沿用原登录规则，不新增returnTo协议。应用内push保留返回栈，直接地址提供“返回练习偏好”。进入或返回不创建练习、不打开麦克风、不控制媒体。

固定go_router版本默认不把imperative push反映至浏览器地址。应用router生命周期内明确启用URL反映，并在dispose恢复原选项。编码浏览器历史以base URI恢复时，只依据本次incoming RouteInformation的合法review URI和encoded Map状态保留阅读来源，不用当前页面猜历史目的地；覆盖恢复/失联、前进历史及未设难度的新账号。显式返回/account和signedOut继续原账号路由，来源仍经本人GET核对。

## 显示边界

来源未登记/保存中、任务未建、等待、blocked、failed、不可评价、有效空建议和成功分别呈现。失败读和身份变化撤旧，不以空态掩盖错误。仅展示后端有效结果的实际0–3项、精确原话、建议和解释；纠错、表达更自然及拓展表达各有文字标签。识别文字依据和保存缺口提示独立保留，不由复盘结果推断可信终止、实际音频播放或费用已停止。

没有接口依据的分数、优点、练习时长和下次建议不展示。本单元没有完整对话、话轮跳转、逐句重练、完整历史或删除。模型默认Unavailable；预览/浏览器验收夹具仅验证页面与真实HTTP流程，不证明语言建议质量。

## 布局与独立预览

沿用应用主题/字体，LayoutBuilder单列阅读区max680、SafeArea与整页滚动；窄屏按钮可换行，至少48逻辑像素。动作区位于稳定页标题之后、动态保存/状态和建议列表之前，避免读取撤旧/恢复后把原键盘焦点推到三张卡片后；不以自动抢焦点或固定栏补偿。原话、建议和解释可选择，长文本不截断。标题语义和状态播报不包住整份结果，不抢文本选择焦点。

独立widget previews包含浅色三项、深色320宽/200%文字、blocked和空态，经过`previewWithFonts`加载本地中文；样例标明预览性质，无API或凭证，不作正式页面fallback。验证结果和限制单独记录于[验收报告](../development/2026-10-21-review-page-verification.md)。

## 当前操作资格（2026-10-24）

点击时同时核对当前Route、最新URI、已登录owner、账号非busy、当前provider/controller和控制器非busy。生成确认绑定实际展示的completion；重试、原请求核对和结果定位/重练再绑定实际展示job，刷新后不能把旧确认用于新来源。原请求仍由既有客户端保留key/body，不重新生成。

账号操作期间保留已读取结果，所有动作禁用并明确显示账号操作提示，不冒充正在读取或隐藏“练这一句”。未连接页的旧重新连接回调先检查mounted/当前页面，再读取当前账号，只在仍不可达且非busy时恢复。返回同样检查当前页面，已销毁回调不读取WidgetRef。见[验证](../development/2026-10-24-review-action-guards-verification.md)。
