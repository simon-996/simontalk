# 有界媒体收尾与内存中断前缀验证

日期：2026-10-21（Asia/Shanghai，本单元从2026-10-20开始）。依据[设计](../superpowers/specs/2026-10-20-bounded-media-drain-design.md)、[计划](../superpowers/plans/2026-10-20-bounded-media-drain.md)与[集中契约](../architecture/2026-10-20-practice-completion-and-review-contract.md)。

## 实际交付

- 正常end独立于立即stop/dispose。首次结束同步停止Web采集、上行及本地声音，只保留原确认通道；默认3秒、配置1–5秒，取原租约更早截止，重复动作复用同一Future，不因回调或HTTP顺延。停续租，已发续租成功/失败均不能重开/提前截断收尾；账号、后台、传输故障和销毁仍立即释放。
- TurnStartedUpdate登记尚无字幕的用户输入与AI response，revision=0不充当识别；首次final前允许原turn的providerItem单向绑定。冻结集合只接原通道/话轮的final、修订及相应播放事实，不接新turn或临时字幕。协议beginDrain一次，输入完成/原response取消控制去重，普通send关闭。同步返回事实通过32条/128KiB受限队列，输出冻结后依序验证。
- freezeResponse独立封存设备对齐前缀的文字/播放revision、停止上限和原因。新final仍将当前播放重置unknown，旧可靠前缀可按旧版本作为interruptedPrefix使用，不进入最终文字API。revoke入口可撤销明确失效的对齐依据，正文与前缀共享原262144字节预算。
- 中断后新回复需先准备原scope的不可变context token，最多发送一次对应控制，并取得同token/当前projection revision/原通道的截断确认。旧确认、复制同版本token或其他通道不能放行。用户facts继续接收；原窗口内旧AI final及合法播放仍投影/保存，而已确认token不变。明确推翻已用前缀时先撤销资格，再context_invalidated安全停止。
- 正常收尾和pending journal由账号作用域持有。离开页面不打断draining或未确认保存；active离页先同步停媒体，失败pending仍可显式retry。媒体关闭且全部确认后释放keepAlive，无页面订阅时销毁正文。真实journal在finish且queue空或最后ACK后清内部投影；该private字段释放经源码复核，没有新增测试专用getter。账号变化清内容并取消旧请求，通知重入有保护。

## 最终检查

| 检查 | 实际结果 |
| --- | --- |
| Flutter完整测试 | **494项通过**，约14秒；前批435，本批新增59 |
| 新增Flutter覆盖 | 投影14、协调器35、provider7、journal3 |
| Node传输/启动/实际Dart桥 | **58项通过**，约0.66秒；前批51，本批新增7 |
| flutter analyze --no-pub | 无问题，2.2秒 |
| Dart格式 | 89文件，0更改 |
| Web release | **35.3秒通过**，no-pub、no-web-resources-cdn、开发API127.0.0.1:8000 |
| 发布字体 | 保留30,890 Unicode映射；WOFF2 7,782,072字节；发布包中文与本地Roboto匹配 |
| 依赖与后端 | pubspec.lock无差异；未改API/迁移，未重跑后端276项或实际HTTP存储验收 |
| 文档 | 本地检查15份Markdown、155处本地链接/标题锚点及围栏通过；git diff --check通过 |

本机日志：`/tmp/simontalk-drain-all-flutter-final.log`、`/tmp/simontalk-drain-node-final.log`、`/tmp/simontalk-drain-web-build.log`。日志不是仓库制品，不含真实练习正文或凭证。Web构建的Wasm dry run不计为Wasm/原生平台验收。

## 失败证据与复核

先运行缺失end/freeze/beginDrain的失败测试，再实现。新增同步协议final回归先实际失败（原Hello未被替换），随后增加有界暂存；provider离页保存先失败，再实现持有及成功释放。首次provider夹具误走默认HTTP信令、销毁时遗漏Riverpod零时长timer属于测试问题，修正夹具后才记录有效行为失败。

独立规格审查发现并修复：在途续租失败截断收尾、在途播放被drain解除后误当故障、撤销依据缺协议入口、未确认上下文可发起新response、上传确认后保留正文。新增回归观察到相应失败后再修复。上下文门初版丢弃确认后的旧AI终态，复审指出与集中契约冲突；改为固定历史token且继续接收原窗口内事实，对明确推翻已用依据的情况撤销并安全停止。最终五项规格复审及独立代码质量审查未发现剩余确定问题；质量审查另复跑四文件79项和Node传输29项通过。

## 证据边界和下一步

媒体、归一化供应商协议和deviceOutputAligned来源仍是明确测试替身；Node桥实际编译Dart→JS，但没有物理麦克风、耳机、供应商语音或真实上游截断验收。尚无供应商可核验完成信号，因此保守等待固定截止，结束为tail_unconfirmed，不以空队列/用户final提早判齐。真实自动回复与旧音频路由仍须证明可控，不能仅凭本地context门开放准入。

准入/网关/协议继续Unavailable；本地关闭和保存成功均不证明上游终止、占用解除或费用封顶。没有新增正式练习/保存页面、播放持久化、服务端end/finalize、30秒补交窗口、反馈或重练。持久文字AI播放仍unknown，刷新后内存前缀不能恢复。未新增浏览器缓存或保存原音频，本次未造开发库练习或调用模型。

下一单元接播放/前缀的持久证据，再推进服务端结束固化及配套补交截止；可信终止/准入能力与供应商账号、地域和预算仍按既定暂缓边界处理。原生暂停。工作保留在feat/account-foundation，已有文档改动保留；本单元未提交、推送或部署。
