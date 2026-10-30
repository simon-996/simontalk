# Review Jobs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement the backend unit, followed by independent specification and quality review. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将已验证复盘输入接入持久、受限重试的反馈任务和有效结果存取。

**Architecture:** 专用Job/Attempt/Action/Result表和固定输入/策略绑定；短事务领取、事务外gateway、fencing后校验提交。默认gateway不可用，不调用模型。

**Tech Stack:** FastAPI/SQLAlchemy/PostgreSQL17/Alembic、asyncio、pytest；客户端不变。

---

依据[完整设计](../specs/2026-10-21-review-jobs-design.md)，本机现有功能分支继续工作并保留全部dirty。不提交/推送/部署/调用模型。实施agent独占后端与simontalk_test；root只做文档、只读复核和释放后的独立验证。

### Task 1: 任务、worker、结果与本人端口

**Files:** 新`services/api/src/simontalk_api/review_jobs.py`（本人任务/幂等/读取）、`review_worker.py`（领取/生成/回写/runner）、`review_gateway.py`（显式能力和Unavailable）、`review_job_routes.py`；修改models.py/main.py/config.py/offer_body_limit.py/pyproject.toml；单个新Alembic迁移；新`tests/test_review_jobs.py`与`test_review_worker.py`。

- [x] 先RED：在已建review input夹具上断言POST review为202、默认blocked/0次；实际缺路由404后再实施。

```python
def test_default_review_is_durably_blocked(client, ready_input):
    path, headers, binding = ready_input
    response = client.post(path, headers=headers, json=binding)
    assert response.status_code == 202
    assert response.json()["status"] == "blocked"
    assert response.json()["attempt_count"] == 0
```

- [x] 建4表约束/级联/无正文尝试保留与迁移，实现本人create/retry/纯读、Action key精确绑定和同输入复用，固定generation策略；来源核对调用既有review input与quote门。
- [x] 先测试gateway只收到安全targets、调用时可另取Practice锁，再实现claim/await8秒/commit；非法quote/旧fence/超时/删除/禁用/输入改变不能落库，有效0–3项原子固定结果及stable item IDs/hash。
- [x] 覆盖两个worker竞争、重启过期running、明确已知错误退避、无幂等未知阻止重试、有幂等固定logical key及3次上限；实现有界runner并接lifespan，默认Unavailable不发请求，shutdown收敛且不影响现有maintenance。
- [x] 补鉴权/CSRF/8KiB五秒、结果只读完整性、Action重放与陈旧retry、用量unknown/null/清理只留metadata、测试fixture并发边界；目标与完整API/Ruff通过。测试库降到4c913f2d8e71再升新head、metadata一致后通知root释放数据库。

### Task 2: 独立复核

- [x] 规格审查任务状态/调用权限/引用/幂等/输入边界；需修项补RED后复审通过。
- [x] 再质量审查锁序/租约/并发/重启/资源上限/迁移及默认关闭；修后复审通过。

### Task 3: 实测与交接

- [x] root独立测试库实际HTTP验证default blocked、no-evaluable、同输入/key复用、测试gateway异步成功/空建议/错误、GET只读/隔离，清理临时账号/凭证/API；明确gateway为fixture、无真实模型。
- [x] 根任务完整API和静态检查、迁移metadata、开发库原数据保留升级；恢复默认Unavailable API并验live/ready。
- [x] 新架构/验证报告与集中契约/技术/路线/总纲/验证/localdev/HANDOFF同步，链接/空白/锁文件检查；不把后端fixture反馈当真实语音/语言质量或页面完成。
