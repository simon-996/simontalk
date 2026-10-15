# SimonTalk AI 协作入口

## 开始工作前

先完整阅读根目录 [HANDOFF.md](HANDOFF.md)，理解项目立意、当前阶段、已完成事项、下一步和当前工作边界。随后检查本地 Git 状态，再按任务阅读相关规格。不要仅凭本文件、旧对话或文件名推断进度。

当前阶段、最近进展和下一步统一在 HANDOFF.md 维护；本文件只维护长期适用的协作规则。接手时如有更新的用户指令，以最新指令为准，并同步状态文档。

## 项目立意

SimonTalk 是面向本人和少量朋友、主要在中国大陆使用的英语口语陪练应用。使用 Flutter 覆盖 iOS、Android、Web，核心是自然实时对话、语音插话、每人独立难度、会后复盘和逐句重练。整体采用轻量语音伙伴方向，逐步做成能长期使用的成熟产品。

## 工作方式

- 默认使用中文沟通，说明结论、实际验证结果、剩余问题和下一步。
- 每次完成一组具体、可验证、可接入最终产品的工作；用户要求按正式产品标准逐步推进，不以草稿、占位页面或脚本演示代替真实功能。
- 已确认、工程建议、供应商候选和实际验证结果分别标明。已安装 skill、已有页面或供应商宣传都不构成集成成功的证据。
- 在最新授权范围内主动完成工作，常规可逆工程选择不反复请求确认；只询问确实缺少、会影响下一步的输入，并继续可独立推进的工作。
- 新阶段开始前核对路线与现状，完成后更新证据。最新用户明确要求进入开发时，应更新交接状态，不因旧文档长期停留在文档阶段。
- 先检查工作区，保留现有改动；提交、推送、部署和服务调用按当前用户授权执行。提供仓库地址本身不等于要求立即推送。
- 只把验证过的结果写成完成。功能与真实数据逐步接通，测试替身和组件预览要明确区分。

## 仓库与规格

使用一个 GitHub 仓库：[simon-996/simontalk](https://github.com/simon-996/simontalk)，主分支 main。目录职责见 [README.md](README.md)，客户端和后端可独立发布。

| 要了解什么 | 阅读哪里 |
| --- | --- |
| 当前状态、下一步、交接更新 | [HANDOFF.md](HANDOFF.md) |
| 需求、已确认决策、首版范围 | [产品总纲](docs/superpowers/specs/2026-10-15-simontalk-mvp-design.md) |
| 阶段顺序与完成标准 | [建设路线](docs/roadmap/2026-10-15-product-roadmap.md) |
| 操作、页面状态和异常流程 | [交互规格](docs/design/2026-10-15-screen-and-interaction-spec.md) |
| 颜色、字体、组件和动效 | [视觉规范](docs/design/2026-10-15-visual-design-spec.md) |
| 模块、数据、接口与可靠性 | [技术设计](docs/architecture/2026-10-15-technical-design.md) |
| 实测方法、指标及验收 | [验证计划](docs/validation/2026-10-15-validation-plan.md) |

设计类任务使用可用的 Flutter/UI skills，并以本项目规格协调其通用建议。不要把 React、Tailwind 或网页动效方案直接带入 Flutter。Skills 的安装记录和使用边界见视觉规范；换环境后先确认实际可用性。

## 结束工作前

有实质进展时更新 HANDOFF.md：当前阶段、本次完成及证据、尚未完成、下一步和所需输入。产品决定同步总纲，功能变化同步对应规格。保持当前状态简洁、准确，避免只在对话中留下进度。

<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tools** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them. `codegraph_node` returns one symbol's source + callers, or reads a whole file with line numbers. If the tools are listed but deferred, load them by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` and `codegraph node <symbol-or-file>` print the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->
