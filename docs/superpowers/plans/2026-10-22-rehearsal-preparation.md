# Rehearsal Source and Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development with one implementation agent and independent specification then quality review. Steps use checkbox (`- [x]`) syntax.

**Goal:** 将普通练习有效建议冻结为可核验目标，原子创建独立一级重练准备，并提供来源及同级记录只读API。

**Architecture:** 沿用原PracticeSession生命周期/占用/偏好/准入，以kind和同账号ordinary父复合外键强制一级关系；复用原review完整来源/quote门，不新建媒体或评价适配。完整字段/错误/锁序/分页见[设计](../specs/2026-10-22-rehearsal-preparation-design.md)。

**Tech Stack:** FastAPI/Pydantic/SQLAlchemy/PostgreSQL17/Alembic；无新依赖，Flutter不改。

---

复用当前dirty功能分支，保留原改动；不stage/commit/push/deploy，不真实模型/供应商或原生。持续工程授权覆盖常规可逆选择，不再逐项审批。实施agent独占services/api及默认simontalk_test/pytest/Ruff；root只文档与不同专属测试库fixture，审查只读。

## Task 1: 完整重练服务端单元

**Files:** Create `services/api/src/simontalk_api/rehearsal_targets.py`（完整来源目标/固定快照读取）、`rehearsals.py`（事务创建/同级seek）、`rehearsal_routes.py`；Create `services/api/tests/test_rehearsal_targets.py`、`test_rehearsal_preparations.py`；Create `services/api/alembic/versions/1a6de74c9f20_add_first_level_rehearsals.py`。Modify `models.py`的PracticeSession、`practice.py`的PracticeOutput及共同不commit构造helper、`main.py`只注册新router、`offer_body_limit.py`仅加入新POST路径的8KiB门；普通准备测试仅按需要补回归，不重写既有安全门。

- [x] 写真实已sealed有效item HTTP夹具，先运行来源目标GET预期200而当前404的RED。

```python
response = client.get(
    f"/v1/practice-sessions/{source_id}/review-items/{item_id}/rehearsal-target",
    headers=headers,
)
assert response.status_code == 200
assert response.json()["source_text"] == original_final_text
```

- [x] 按设计实现kind及源六字段/ordinary空值/同账号ordinary父FK和删除级联；保留原mode及普通数据，添加空库降升与非空拒降测试。关键约束：

```python
UniqueConstraint("id", "user_id", "kind", name="practice_id_owner_kind")
ForeignKeyConstraint(
    ["source_session_id", "user_id", "source_kind"],
    ["practice_sessions.id", "practice_sessions.user_id", "practice_sessions.kind"],
    name="practice_rehearsal_source", ondelete="CASCADE",
)
```

- [x] 完整核验当前ReviewJob/Result/ReviewInput并精确匹配同scope用户decision，派生设计中的rehearsal_target_v1；text_only不带前文、conversation_context只取已验证安全前文，64KiB实际JSON/UTF8限额。GET零写/无admit，记录目标hash且不把示例写成转写。

```python
job = read_review_job(db, user_id, source_session_id)
data = read_review_input(db, user_id, source_session_id)
item = next((row for row in job["result"]["items"] if row["id"] == str(item_id)), None)
```

以上执行前须按设计核对ordinary及成功状态；之后必须匹配完整connection/turn/revision、合法精确quote/允许basis，不能只靠上述item查找返回正文。

- [x] 提取原准备的共同占用/偏好/准入构造helper（不commit）；新POST先同owner key摘要门及User→来源锁，重验确认hash，再一次事务保存独立PracticeSession/target。默认503/占用409零半记录；同key复放不重admit/更新时间，改变来源/hash/override冲突，新key上次结束后新建同级。

```python
request_digest = digest(canonical({
    "operation": "rehearsal_create",
    "source_session_id": str(source_session_id),
    "item_id": str(item_id),
    "body": payload.model_dump(mode="json"),
}))
```

- [x] 实现子目标读取的冻结hash/结构和当前源逐字段核验；失效409、来源删除404，原子记录/原普通wrapper不受影响。实现同级seek：父普通本人门、cursor同父/账号门、limit+1读取，无正文元数据与next_before_id。

```python
query = query.order_by(PracticeSession.created_at.desc(), PracticeSession.id.desc()).limit(limit + 1)
```

- [x] 新路由沿鉴权、CSRF/Origin及锁后复验；POST前8KiB/五秒接收门。目标/创建回归覆盖设计第5节列出的所有具体边界，特别父删除竞态、多级数据库拒绝、纯GET完整业务行相等、默认admission及unknown不绕过、不同key同级、无snapshot半写。
- [x] `uv run --locked --no-sync pytest tests/test_rehearsal_targets.py tests/test_rehearsal_preparations.py`后完整`pytest`、`ruff check .`、`ruff format --check .`、metadata/head/迁移降升通过；给RED和最终命令/数目/日志，释放工具链/默认测试库。独立规格审通过后才独立质量审，确定问题由同实施agent先RED修复再复审。

## Task 2: 主任务独立验证、迁移与交接

- [x] root独立完整API/Ruff/metadata；专属测试库真实HTTP验证有效目标→默认拒绝无记录→隔离admission创建/同key确认→安全取消→新key第二同级→列表/固定目标→他人404/源改409及零额外模型调用。默认开发库不放示例数据。
- [x] 独立迁移空库降升与metadata、保留历史普通记录；双审/检查通过后备核开发库17项跟踪表计数/旧head与普通数据，仅升级schema，默认关闭gateway API8000重启live/ready，新路径鉴权门通过。
- [x] 清理专属临时账号/邀请/库/凭证/脚本/API，验证开发库原17项跟踪表计数不变、锁文件/空白/本地文档链接通过。更新HANDOFF、架构/验证报告及中央规格，明确客户端重练入口、改善评价、真实媒体、历史/删除仍未接通，保存文字浏览器验收仍待补。


## 执行结果

全部后端步骤已完成，见[验证报告](../../development/2026-10-22-rehearsal-preparation-verification.md)。规格审后质量审发现同级列表缺索引，先schema RED再补rehearsal_parent_seek部分索引，独立复审及真实查询计划通过。最终641全量/86目标，root另验640全量及最终86目标；schema-only开发迁移/17项跟踪表计数保留、Unavailable API健康及临时资源清理完成。Flutter/真实媒体/改善评价/删除产品流程不在本批，后续继续按总纲接入。
