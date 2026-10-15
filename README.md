# SimonTalk

一个面向自己和少量朋友的英语口语陪练项目，主要在中国大陆使用。产品方向是轻量语音伙伴：自然对话、独立难度、会后复盘和逐句重练。

GitHub 仓库：[simon-996/simontalk](https://github.com/simon-996/simontalk)。Git 远端 `origin` 使用 `https://github.com/simon-996/simontalk.git`，初始分支为 `main`。

当前阶段、完成情况和下一步统一见 [HANDOFF.md](HANDOFF.md)。技术栈中 Flutter 已确认，其余方案的决策状态见产品总纲。

AI 接手先读根目录 [AGENTS.md](AGENTS.md)，再读 [HANDOFF.md](HANDOFF.md)。交接文档集中维护当前阶段、最近进展、下一步、所需输入和工作边界；支持 AGENTS.md 的工具可通过该入口接手，其他工具可由用户指定先读这两个文件。

给新 AI 的启动指令：“先阅读项目根目录的 AGENTS.md 和 HANDOFF.md，核对实际仓库状态，再按交接中的当前阶段与下一步继续。”

建设顺序见[产品建设路线](docs/roadmap/2026-10-15-product-roadmap.md)：方案准备 → 工程底座 → 真实语音 → 学习闭环 → 可靠性与成本 → 三端试用 → 持续成熟。每阶段都有具体产物和完成标准。

## 仓库组织

项目采用一个 GitHub 仓库，统一管理客户端、后端、文档和部署配置；客户端与后端分别构建、部署，不要求同时发布。

| 路径 | 职责 |
| --- | --- |
| apps/client/ | Flutter 客户端，覆盖 iOS、Android、Web |
| services/api/ | 业务后端 |
| docs/ | 产品、设计、技术和验收文档 |
| deploy/ | 部署配置与运行说明 |

各目录随对应开发阶段建立；实际已有内容以仓库文件和交接状态为准。

## 阅读顺序

1. [产品与决策总纲](docs/superpowers/specs/2026-10-15-simontalk-mvp-design.md)：已确认方向、首版功能、建议和开发前输入。
2. [页面与交互规格](docs/design/2026-10-15-screen-and-interaction-spec.md)：各页面、状态、导航、退出、辅助、复盘、重练与异常。
3. [视觉设计规范](docs/design/2026-10-15-visual-design-spec.md)：已安装的设计 skills、配色、字体、组件、伙伴、动效、响应式和视觉验收。
4. [技术设计](docs/architecture/2026-10-15-technical-design.md)：客户端与后端、实时语音、数据、接口、认证和可靠性。
5. [验证与验收计划](docs/validation/2026-10-15-validation-plan.md)：语音原型的测试方式、质量指标、成本与功能验收。
6. [产品与技术调研](docs/research/2026-10-15-product-and-stack-review.md)：商业产品、GitHub 项目、官方来源与证据边界。

## 文档约定

- 用户已确认、设计建议、技术候选和待验证结论分别标明。
- 产品总纲维护决策状态；其他文档细化各自负责的范围。
- HANDOFF.md 维护当前进度和下一步；有实质进展时同步更新，接手时仍需核对实际仓库状态。
- 页面行为以交互规格为准，视觉角色与尺寸建议以视觉规范为准，接口和数据以技术设计为准，指标以验收计划为准。
- 调研说明公开资料和源码实际展示的能力，不作为本项目已经实现的证据。
- 当前允许推进的工作以最新用户指令和 HANDOFF.md 为准；进入新阶段时同步更新交接，避免沿用旧阶段的工作边界。
