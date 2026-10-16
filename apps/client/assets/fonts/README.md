# Web 字体

Web使用完整Noto Sans SC的WOFF2压缩产物，保留源字体的30,890个Unicode映射与100–900可变字重；原生端继续使用系统字体。不依赖运行时Google Fonts服务。

来源：Google Fonts 官方仓库 `ofl/notosanssc/NotoSansSC[wght].ttf`，2026-10-16 获取；原始文件与许可证一同保存。上游元数据记录的 Noto CJK 来源提交为 `523d033d6cb47f4a80c58a35753646f5c3608a78`。许可证见 [OFL.txt](OFL.txt)。

`NotoSansSC.ttf`保留为源文件，不进入发布Web包；`NotoSansSC.woff2`为完整转换，17,772,300 → 7,782,072字节，减少56.2%，没有裁字或删减字重。FontLoader只在Web加载，成功前保留HTML启动提示；长度与SHA-256不匹配时显示启动重试。摘要使用浏览器WebCrypto，运行要求HTTPS或受信任的localhost/127.0.0.1；普通局域网HTTP不属于支持入口。

重新生成（Python3.11/3.12；处理库版本记录在脚本中，使用可信源文件）：

```sh
uv run scripts/prepare_web_fonts.py
uv run scripts/check_web_fonts.py
uv run scripts/check_web_fonts.py --web-build apps/client/build/web
```

命令从仓库根目录运行。生成器还更新Dart长度/摘要元数据；校验覆盖完整映射、字形轮廓、度量、布局、字重变化和许可证元数据。CI只校验已提交产物，不重复耗时压缩。字体依旧约7.8MB，文件大小不代表真实下载量或启动延迟；大陆真实网络性能与缓存策略仍待验证。源字体未覆盖字符的回退质量仍需验证。

另保存同一官方仓库 `ofl/roboto/Roboto[wdth,wght].ttf`，作为 Flutter Web 引擎必需的默认回退字体，防止引擎启动时隐式从 Google 下载 Roboto。来源元数据提交 `91d5d3e5b81efa04a77925cc609fdcdd7ee663d1`，许可证见 [Roboto-OFL.txt](Roboto-OFL.txt)。
