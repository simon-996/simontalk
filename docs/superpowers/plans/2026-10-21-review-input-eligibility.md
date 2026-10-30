# Review Input Eligibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement the backend unit and perform specification review followed by quality review. Steps use checkbox (`- [x]`) syntax.

**Goal:** 从已封存的真实实收事件产生持久、可追溯的复盘输入与严格引用门。

**Architecture:** 独立策略投影+无正文持久快照，绑定原seal及policy/hash；本人POST创建/精确重放、GET纯读。内部输出校验只接受原用户版本及允许依据，不生成反馈或改写旧seal。

**Tech Stack:** FastAPI/Pydantic、SQLAlchemy、PostgreSQL17、Alembic、pytest；客户端不变。

---

按[完整设计](../specs/2026-10-21-review-input-eligibility-design.md)执行。复用当前功能分支保留全部已有改动，不提交/推送/部署/调用供应商。后端实施单一agent拥有以下文件，root只做独立验证及文档。

### Task 1: 资格投影、持久输入与API

**Files:** 新`services/api/src/simontalk_api/review_input_policy.py`（纯策略）、`review_inputs.py`（受权持久/读取/精确引用）、`review_routes.py`；修改`models.py/main.py/pyproject.toml`；新单表Alembic版本；新`tests/test_review_inputs.py`及策略/引用测试。

- [x] RED：先新增以下接口测试，运行`uv run --locked --no-sync pytest tests/test_review_inputs.py -x`，确认缺端口404而非环境错误。

```python
def test_review_input_requires_sealed_origin(client, prepared):
    result = client.post(f"/v1/practice-sessions/{prepared.session['id']}/review-input",
                         headers=prepared.headers,
                         json={"input_revision": 1, "input_hash": "a" * 64})
    assert result.status_code == 409
    assert result.json()["code"] == "completion_not_sealed"
```

- [x] 建立设计要求的ReviewInput模型和单表迁移，实现创建/重放/纯读及sealed精确scope/hash读取；不改候选策略或旧快照。用实际create/reserve/transcript/end/manifest夹具形成输入，验证两次POST和GET相同、原hash/租约/终止不变。
- [x] 策略测试先断言非空用户final缺confidence仍eligible；旧r1与最新空r2均excluded，AI只有可靠prefix进入之前的context。覆盖设计中所有缺口/角色/版本/顺序边界后实现纯派生及预算检查。
- [x] 内部引用门先验证wrong quote/old revision/assistant/context禁止及超3项均整体拒绝，再实现0–3项严格结构与精确Unicode引用；测试无可评价正常业务结果和删除/旧hash失效。
- [x] 目标回归、完整API、Ruff通过；测试库head降到0e1874613efa再升head及`alembic check`无差异。单agent独占simontalk_test，结束后通知root释放；不碰开发库。

### Task 2: 规格与质量复核

- [x] 独立规格检查资格与引用不扩大证据、幂等/作用域、缺口定位和存储不含正文；修复后复审通过。
- [x] 再独立质量检查锁序、资源上限、事务/身份/晚数据、hash校验和新迁移；修复后复审通过。

### Task 3: 实际验证和交接

- [x] root在独立测试库启临时准入API，用真实HTTP创建非空用户/AI未知播放与正常end/manifest，POST输入/重放/GET核对资格、他账号404、无可评价与未sealed冲突；精确清理临时账号/凭证/API。
- [x] root完整API、静态检查、迁移metadata后，备查原开发数据并升级新head、恢复默认关闭准入/网关API并验live/ready。客户端无变更不虚构新UI/语音证据。
- [x] 更新新架构/实测报告、集中契约/路线/总纲/技术/验证及HANDOFF；本地链接和diff空白通过，锁文件保持。标明后续反馈任务/正式页面/供应商和可信终止仍待实现。


最终证据：[实测报告](../../development/2026-10-21-review-input-eligibility-verification.md)。根任务完整API462通过（85.66秒）、Ruff/66 Python格式、独立实际HTTP/内部引用门、测试库迁移降升/metadata及开发库保留数据升级通过。规格复审后独立质量审查通过。客户端未修改，模型/正式页面未实现；全部临时fixture已清理，默认API恢复，未提交/推送/部署。
