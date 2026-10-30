# 真实音频输入与复盘任务组合验证计划

**Goal:** 补齐真实音频上行/识别及新复盘候选接生产worker后的证据，明确不能验收的上下文控制。

**Architecture:** 语音使用已有私有配置的受控WebSocket实验，固定合成英文音频，不采集设备。复盘使用独立PostgreSQL测试库/真实API及worker，仅显式替换该实验应用的复盘网关；准入不开放。测试中分别标记真实模型和替身，不将离线重放称为实时产品闭环。

**Tech Stack:** 现有Python3.13/HTTPX/pytest/PostgreSQL17；临时websockets15.0.1用于实验，仓库不加依赖。

- [x] 读取交接、Git及当前收尾/准入契约，确认789既有文件并保存摘要；官方资料仍无本型号完整退出/截断契约。
- [x] 合成16kHz单声道16bit固定英文，按实时节奏上传；配置确认→commit→ASR final→response done，记录用量和关联时间，不保存回复音频。
- [x] 使用实际assistant item在取消后仅发送一次conversation.item.truncate，30秒接收总截止；无确认则保留未验证，不补造回调。
- [x] 扩充test_qwen_review_gateway.py的exchange测试工厂model参数（默认qwen-flash），将test_qwen_review_gateway_integration.py中成功/零项/非法引用/未知/删除晚结果/配置变更场景参数化为两个型号，真实SQL与worker仍使用MockTransport；所有计费I/O留在独立人工探针。
- [x] 独立创建simontalk_voice_review_20261025_test，目标运行配置/复盘组件及组合测试；不使用默认测试库或开发库跑pytest。
- [x] 对真实ASR已得到的英文在隔离API封存，显式安装qwen3.8-flash真实网关，执行一次worker，核返回/存储用量、GET纯读、重启读取、历史/他账号隔离及删除；断言未知占用按实际实验来源区分，不伪造真实媒体会话已入库。
- [x] 核对开发21表全行摘要，关闭并删除本轮测试库/临时脚本及合成音频；检查原文件保留、Ruff/格式/锁及新文档/证据链接，更新HANDOFF。无提交、推送、部署或原生构建。
