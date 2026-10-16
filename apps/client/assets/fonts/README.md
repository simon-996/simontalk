# Web 字体

Web 使用随应用分发的 Noto Sans SC 可变字体，覆盖简体中文与拉丁文字；原生端继续使用系统字体。不依赖运行时 Google Fonts 服务。

来源：Google Fonts 官方仓库 `ofl/notosanssc/NotoSansSC[wght].ttf`，2026-10-16 获取；原始文件与许可证一同保存。上游元数据记录的 Noto CJK 来源提交为 `523d033d6cb47f4a80c58a35753646f5c3608a78`。许可证见 [OFL.txt](OFL.txt)。

本地字体增加 Web 首次下载量。发布时使用压缩和缓存，并在大陆真实网络测试首次启动；当前尚未完成该性能验收。罕见汉字、特殊符号和其他未覆盖字符的回退质量仍需验证。

另保存同一官方仓库 `ofl/roboto/Roboto[wdth,wght].ttf`，作为 Flutter Web 引擎必需的默认回退字体，防止引擎启动时隐式从 Google 下载 Roboto。来源元数据提交 `91d5d3e5b81efa04a77925cc609fdcdd7ee663d1`，许可证见 [Roboto-OFL.txt](Roboto-OFL.txt)。
