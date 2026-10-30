"""Candidate HTTP boundary: all supplier I/O uses MockTransport, never a real key."""

import asyncio
import copy
import importlib
import importlib.util
import json
from uuid import uuid4

import httpx
import pytest

from simontalk_api.review_gateway import ReviewGatewayError, ReviewRequest, ReviewUsage


def test_candidate_module_exists():
    assert importlib.util.find_spec("simontalk_api.qwen_review_gateway") is not None, (
        "Qwen review adapter is missing"
    )


@pytest.fixture
def module():
    name = "simontalk_api.qwen_review_gateway"
    assert importlib.util.find_spec(name) is not None, "Qwen review adapter is missing"
    return importlib.import_module(name)


def settings(module, **changes):
    return module.QwenReviewSettings(
        **{
            "workspace_id": "test-workspace",
            "model": "qwen-flash",
            "config_id": "review-test-v1",
            "api_key": "secret-test-only",
            **changes,
        }
    )


def request(**changes):
    return ReviewRequest(
        **{
            "logical_request_key": f"review:{uuid4()}",
            "generation_policy_version": "review_generation_v1",
            "targets": (
                {
                    "source_connection_id": str(uuid4()),
                    "source_turn_id": str(uuid4()),
                    "revision": 1,
                    "text": "Yesterday I go to the park.",
                    "eligibility": "eligible",
                    "allowed_bases": ["text_only", "conversation_context"],
                    "context_before": [
                        {
                            "role": "assistant",
                            "text": "What did you do yesterday?",
                            "turn_id": str(uuid4()),
                            "revision": 1,
                        }
                    ],
                },
            ),
            **changes,
        }
    )


def suggestion(**changes):
    return {
        "target_id": 0,
        "exact_quote": "I go",
        "kind": "correction",
        "basis": "text_only",
        "explanation": "这里表达过去发生的事，可以用过去式。",
        "suggestion": "I went to the park yesterday.",
        **changes,
    }


def envelope(content=None, **changes):
    return {
        "id": "chatcmpl-test",
        "object": "chat.completion",
        "model": "qwen-flash",
        "choices": [
            {
                "index": 0,
                "finish_reason": "stop",
                "message": {
                    "role": "assistant",
                    "content": content
                    if content is not None
                    else json.dumps({"suggestions": [suggestion()]}, ensure_ascii=False),
                },
            }
        ],
        "usage": {"prompt_tokens": 150, "completion_tokens": 40, "total_tokens": 190},
        **changes,
    }


class Parts(httpx.AsyncByteStream):
    def __init__(self, *parts):
        self.parts, self.closed, self.read = parts, False, 0

    async def __aiter__(self):
        for part in self.parts:
            self.read += 1
            yield part

    async def aclose(self):
        self.closed = True


def exchange(
    module, value=None, *, handler=None, status=200, headers=None, raw=None, model="qwen-flash"
):
    data = (
        raw
        if raw is not None
        else json.dumps(value or envelope(model=model), ensure_ascii=False).encode()
    )
    stream = Parts(data)
    calls, clients = [], []

    async def send(sent):
        calls.append(sent)
        if handler is not None:
            return await handler(sent)
        return httpx.Response(
            status,
            headers={"Content-Type": "application/json", **(headers or {})},
            stream=stream,
        )

    def factory():
        client = httpx.AsyncClient(transport=httpx.MockTransport(send), trust_env=False)
        clients.append(client)
        return client

    gateway = module.QwenReviewGateway(settings(module, model=model), client_factory=factory)
    return gateway, calls, clients, stream


def test_one_nonstreaming_request_maps_local_ids_and_real_usage(module):
    gateway, calls, clients, stream = exchange(module)
    source = request()
    result = asyncio.run(gateway.generate(source))
    assert len(calls) == 1 and clients[0].is_closed and stream.closed
    sent = calls[0]
    assert str(sent.url) == (
        "https://test-workspace.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
    )
    assert sent.method == "POST" and sent.headers["Authorization"] == "Bearer secret-test-only"
    assert sent.headers["Accept-Encoding"] == "identity"
    payload = json.loads(sent.content)
    assert payload["model"] == "qwen-flash" and payload["stream"] is False
    assert payload["enable_thinking"] is False and payload["response_format"] == {
        "type": "json_object"
    }
    assert payload["n"] == 1 and payload["temperature"] == 0 and payload["max_tokens"] == 2048
    assert len(payload["messages"]) == 2 and "JSON" in payload["messages"][0]["content"]
    supplied = json.loads(payload["messages"][1]["content"])["targets"][0]
    assert supplied["target_id"] == 0 and supplied["text"] == source.targets[0]["text"]
    assert supplied["context_before"] == [
        {"role": "assistant", "text": "What did you do yesterday?"}
    ]
    for private in [
        source.logical_request_key,
        source.targets[0]["source_connection_id"],
        source.targets[0]["source_turn_id"],
        source.targets[0]["context_before"][0]["turn_id"],
    ]:
        assert private not in sent.content.decode()
    assert "Idempotency-Key" not in sent.headers
    expected = {key: value for key, value in suggestion().items() if key != "target_id"}
    expected |= {
        key: source.targets[0][key]
        for key in ["source_connection_id", "source_turn_id", "revision"]
    }
    assert result.suggestions == [expected]
    assert result.usage == ReviewUsage(150, 40)


def test_capability_is_static_silent_not_idempotent_and_binds_nonsecret_config(module):
    calls = []

    def factory():
        calls.append(True)

    gateway = module.QwenReviewGateway(settings(module), client_factory=factory)
    assert calls == [] and gateway.capability.supports_idempotency is False
    other = module.QwenReviewGateway(settings(module, workspace_id="another-workspace"))
    rotated = module.QwenReviewGateway(settings(module, api_key="rotated-secret"))
    assert gateway.capability.config_id != other.capability.config_id
    assert gateway.capability.config_id == rotated.capability.config_id
    assert len(gateway.capability.config_id) <= 128
    assert "secret-test-only" not in repr(settings(module))


def schema_gateway(module, value):
    gateway, calls, clients, stream = exchange(module, value)
    gateway = module.QwenReviewGateway(
        settings(module, model="qwen3.8-flash"), client_factory=gateway._client_factory
    )
    return gateway, calls, clients, stream


def test_schema_candidate_sends_strict_fields_and_maps_real_usage(module):
    gateway, calls, clients, stream = schema_gateway(module, envelope(model="qwen3.8-flash"))
    result = asyncio.run(gateway.generate(request()))
    payload = json.loads(calls[0].content)
    assert payload["model"] == "qwen3.8-flash"
    schema_format = payload["response_format"]
    assert schema_format["type"] == "json_schema"
    assert schema_format["json_schema"]["strict"] is True
    schema = schema_format["json_schema"]["schema"]
    assert schema["required"] == ["suggestions"] and schema["additionalProperties"] is False
    items = schema["properties"]["suggestions"]["items"]
    expected = set(suggestion())
    assert set(items["required"]) == expected
    assert set(items["properties"]) == expected and items["additionalProperties"] is False
    assert items["properties"]["kind"]["enum"] == ["correction", "polish", "extension"]
    assert items["properties"]["basis"]["enum"] == ["text_only", "conversation_context"]
    assert result.suggestions[0]["exact_quote"] == "I go"
    assert result.usage == ReviewUsage(150, 40)
    assert len(calls) == 1 and clients[0].is_closed and stream.closed


@pytest.mark.parametrize("model", ["qwen-flash", "qwen3.8-flash"])
def test_live_misspelled_suggestion_key_is_rejected_with_usage_preserved(module, model):
    item = suggestion()
    item["suggestio"] = item.pop("suggestion")
    value = envelope(json.dumps({"suggestions": [item]}), model=model)
    if model == "qwen3.8-flash":
        gateway, calls, _, _ = schema_gateway(module, value)
    else:
        gateway, calls, _, _ = exchange(module, value)
    result = asyncio.run(gateway.generate(request()))
    assert result.suggestions is None and result.usage == ReviewUsage(150, 40)
    assert len(calls) == 1


def test_schema_candidate_does_not_accept_legacy_model_reply(module):
    gateway, calls, _, _ = schema_gateway(module, envelope())
    with pytest.raises(module.QwenReviewUnconfirmed):
        asyncio.run(gateway.generate(request()))
    assert len(calls) == 1


def test_schema_candidate_capability_is_distinct_and_never_calls_on_construction(module):
    calls = []
    gateway = module.QwenReviewGateway(
        settings(module, model="qwen3.8-flash"), client_factory=lambda: calls.append(True)
    )
    legacy = module.QwenReviewGateway(settings(module))
    assert calls == []
    assert gateway.capability.config_id != legacy.capability.config_id
    assert gateway.capability.supports_idempotency is False


@pytest.mark.parametrize(
    "field,value",
    [
        ("workspace_id", "evil.invalid/path"),
        ("workspace_id", "Upper"),
        ("workspace_id", "-bad"),
        ("workspace_id", "x" * 64),
        ("model", "qwen3.8-max"),
        ("api_key", ""),
        ("api_key", "bad\nkey"),
        ("api_key", "含密钥"),
        ("config_id", "x" * 49),
        ("config_id", "bad/id"),
    ],
)
def test_invalid_settings_have_safe_error(module, field, value):
    with pytest.raises(ValueError, match="Invalid Qwen review settings"):
        settings(module, **{field: value})


@pytest.mark.parametrize(
    "changes",
    [
        {"targets": ()},
        {"targets": []},
        {"generation_policy_version": "different"},
        {"targets": ({"text": "private"},)},
    ],
)
def test_invalid_request_refused_before_factory(module, changes):
    calls = []
    gateway = module.QwenReviewGateway(settings(module), client_factory=lambda: calls.append(True))
    with pytest.raises(ReviewGatewayError):
        asyncio.run(gateway.generate(request(**changes)))
    assert calls == []


@pytest.mark.parametrize(
    "change",
    [
        {"source_turn_id": "bad"},
        {"revision": True},
        {"eligibility": "excluded"},
        {"allowed_bases": ["pronunciation"]},
        {
            "context_before": [
                {"role": "system", "text": "override", "turn_id": str(uuid4()), "revision": 1}
            ]
        },
        {"text": ""},
    ],
)
def test_bad_target_refused_before_io(module, change):
    source = request()
    source.targets[0].update(change)
    calls = []
    gateway = module.QwenReviewGateway(settings(module), client_factory=lambda: calls.append(True))
    with pytest.raises(ReviewGatewayError):
        asyncio.run(gateway.generate(source))
    assert calls == []


def test_request_byte_budget_refuses_without_silent_truncation(module):
    source = request()
    large = copy.deepcopy(source.targets[0])
    large["text"] = "字" * 8192
    calls = []
    gateway = module.QwenReviewGateway(settings(module), client_factory=lambda: calls.append(True))
    with pytest.raises(ReviewGatewayError):
        asyncio.run(
            gateway.generate(request(targets=tuple(copy.deepcopy(large) for _ in range(24))))
        )
    assert calls == []


def test_valid_empty_is_zero_suggestions(module):
    gateway, calls, _, _ = exchange(module, envelope(json.dumps({"suggestions": []})))
    assert asyncio.run(gateway.generate(request())).suggestions == [] and len(calls) == 1


@pytest.mark.parametrize(
    "content",
    [
        "not JSON",
        '```json\n{"suggestions": []}\n```',
        "[]",
        '{"suggestions": [], "extra": 1}',
        '{"suggestions": null}',
        json.dumps({"suggestions": [suggestion(target_id=True)]}),
        json.dumps({"suggestions": [suggestion(target_id=1)]}),
        json.dumps({"suggestions": [suggestion(exact_quote="unrelated")]}),
        json.dumps({"suggestions": [suggestion(kind="pronunciation")]}),
        json.dumps({"suggestions": [suggestion(score=90)]}),
        json.dumps({"suggestions": [suggestion()] * 4}),
        '{"suggestions": [], "suggestions": []}',
        '{"suggestions": NaN}',
    ],
)
def test_invalid_model_content_is_not_fabricated_empty_success(module, content):
    gateway, _, _, _ = exchange(module, envelope(content))
    result = asyncio.run(gateway.generate(request()))
    assert result.suggestions is None and result.usage == ReviewUsage(150, 40)


@pytest.mark.parametrize(
    "usage,expected",
    [
        (None, None),
        ({}, None),
        ({"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}, ReviewUsage(0, 0)),
        ({"prompt_tokens": 15}, ReviewUsage(15, None)),
        ({"prompt_tokens": True, "completion_tokens": 5}, None),
        ({"prompt_tokens": -1}, None),
        ({"prompt_tokens": 1, "completion_tokens": 2, "total_tokens": 9}, None),
    ],
)
def test_usage_missing_is_unknown_not_zero(module, usage, expected):
    gateway, _, _, _ = exchange(module, envelope(usage=usage))
    assert asyncio.run(gateway.generate(request())).usage == expected


def test_unpaired_unicode_from_model_is_invalid_output_before_persistence(module):
    content = json.dumps({"suggestions": [suggestion(explanation="\ud800")]})
    gateway, _, _, _ = exchange(module, envelope(content))
    assert asyncio.run(gateway.generate(request())).suggestions is None


@pytest.mark.parametrize("status", [400, 401, 403, 404, 413, 422, 429])
def test_explicit_rejection_is_permanent_and_error_body_is_never_read(module, status):
    gateway, calls, clients, stream = exchange(
        module, status=status, raw=b"sensitive upstream body"
    )
    with pytest.raises(ReviewGatewayError) as caught:
        asyncio.run(gateway.generate(request()))
    assert caught.value.retryable is False and caught.value.__context__ is None
    assert len(calls) == 1 and stream.read == 0 and stream.closed and clients[0].is_closed


@pytest.mark.parametrize("status", [201, 204, 301, 307, 408, 500, 502, 503])
def test_other_status_is_unknown_and_never_retried(module, status):
    gateway, calls, clients, stream = exchange(module, status=status)
    with pytest.raises(module.QwenReviewUnconfirmed) as caught:
        asyncio.run(gateway.generate(request()))
    assert len(calls) == 1 and stream.read == 0 and stream.closed and clients[0].is_closed
    assert caught.value.__context__ is None and caught.value.__cause__ is None


@pytest.mark.parametrize(
    "headers",
    [
        {"Content-Type": "text/html"},
        {"Content-Encoding": "gzip"},
        {"Content-Length": "-1"},
        {"Content-Length": "1"},
        {"Content-Length": "262145"},
        {"Content-Length": "1, 1"},
    ],
)
def test_invalid_response_headers_fail_closed(module, headers):
    gateway, calls, clients, stream = exchange(module, headers=headers)
    with pytest.raises(module.QwenReviewUnconfirmed):
        asyncio.run(gateway.generate(request()))
    assert len(calls) == 1 and clients[0].is_closed and stream.closed


@pytest.mark.parametrize(
    "raw",
    [
        b"\xff",
        b"not json",
        b'{"object":"chat.completion","object":"chat.completion"}',
        b'{"n": NaN}',
        b'{"n": Infinity}',
        b"[]",
    ],
)
def test_bad_envelope_has_sanitized_unknown_outcome(module, raw):
    gateway, _, _, _ = exchange(module, raw=raw)
    with pytest.raises(module.QwenReviewUnconfirmed) as caught:
        asyncio.run(gateway.generate(request()))
    assert str(caught.value) == "Review generation outcome is unknown"
    assert caught.value.__context__ is None


def test_overflow_stops_without_reading_another_chunk_and_closes(module):
    stream = Parts(b"x" * (256 * 1024), b"x", b"must not read")

    async def handler(_):
        return httpx.Response(200, headers={"Content-Type": "application/json"}, stream=stream)

    gateway, calls, clients, _ = exchange(module, handler=handler)
    with pytest.raises(module.QwenReviewUnconfirmed):
        asyncio.run(gateway.generate(request()))
    assert len(calls) == 1 and stream.read == 2 and stream.closed and clients[0].is_closed


def test_exact_declared_length_and_json_charset_are_accepted(module):
    data = json.dumps(envelope()).encode()
    gateway, _, _, _ = exchange(
        module,
        raw=data,
        headers={
            "Content-Length": str(len(data)),
            "Content-Type": "application/json; charset=utf-8",
        },
    )
    assert asyncio.run(gateway.generate(request())).suggestions is not None


def test_request_sources_are_frozen_while_http_is_pending(module):
    source = request()
    expected = source.targets[0]["source_turn_id"]

    async def handler(_):
        source.targets[0]["source_turn_id"] = str(uuid4())
        source.targets[0]["text"] = "replaced text"
        return httpx.Response(
            200,
            headers={"Content-Type": "application/json"},
            stream=Parts(json.dumps(envelope()).encode()),
        )

    gateway, _, _, _ = exchange(module, handler=handler)
    result = asyncio.run(gateway.generate(source))
    assert result.suggestions[0]["source_turn_id"] == expected


@pytest.mark.parametrize(
    "change",
    [
        {"finish_reason": "length"},
        {"finish_reason": "tool_calls"},
        {"message": {"role": "assistant", "content": "{}", "refusal": "denied"}},
        {"message": {"role": "assistant", "content": "{}", "tool_calls": [{"id": "bad"}]}},
        {"message": {"role": "assistant", "content": "{}", "reasoning_content": "hidden chain"}},
    ],
)
def test_nonfinal_or_nonassistant_output_is_invalid_not_empty(module, change):
    data = envelope()
    data["choices"][0].update(change)
    gateway, _, _, _ = exchange(module, data)
    assert asyncio.run(gateway.generate(request())).suggestions is None


def test_foreign_model_reply_is_unknown(module):
    gateway, _, _, _ = exchange(module, envelope(model="other-model"))
    with pytest.raises(module.QwenReviewUnconfirmed):
        asyncio.run(gateway.generate(request()))


@pytest.mark.parametrize(
    "failure",
    [
        httpx.ConnectError("secret-test-only private input"),
        httpx.ReadTimeout("private response"),
        ValueError("secret-test-only"),
    ],
)
def test_sdk_failure_is_sanitized_without_context(module, failure):
    async def handler(_):
        raise failure

    gateway, calls, clients, _ = exchange(module, handler=handler)
    with pytest.raises(module.QwenReviewUnconfirmed) as caught:
        asyncio.run(gateway.generate(request()))
    assert len(calls) == 1 and clients[0].is_closed
    assert caught.value.__context__ is None and caught.value.__cause__ is None
    assert "secret-test-only" not in repr(caught.value) and "private" not in str(caught.value)


def test_http_stage_timeout_is_unknown_and_closes_client(module, monkeypatch):
    monkeypatch.setattr(module, "_HTTP_TIMEOUT_SECONDS", 0.01)

    async def handler(_):
        await asyncio.sleep(1)
        raise AssertionError("must have been cancelled")

    gateway, calls, clients, _ = exchange(module, handler=handler)
    with pytest.raises(module.QwenReviewUnconfirmed):
        asyncio.run(gateway.generate(request()))
    assert len(calls) == 1 and clients[0].is_closed


def test_external_cancellation_propagates_and_closes(module):
    async def exercise():
        started = asyncio.Event()

        async def handler(_):
            started.set()
            await asyncio.Future()

        gateway, calls, clients, _ = exchange(module, handler=handler)
        task = asyncio.create_task(gateway.generate(request()))
        await started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert len(calls) == 1 and clients[0].is_closed

    asyncio.run(exercise())


def test_default_client_disables_environment_proxy_redirects_and_transport_retries(
    module, monkeypatch
):
    original = httpx.AsyncHTTPTransport
    captured = []

    def transport(**kwargs):
        captured.append(kwargs)
        return original(**kwargs)

    monkeypatch.setattr(module.httpx, "AsyncHTTPTransport", transport)
    client = module._client()
    try:
        assert client.trust_env is False and client.follow_redirects is False
        assert captured == [{"trust_env": False, "retries": 0}]
    finally:
        asyncio.run(client.aclose())


def test_existing_application_factory_stays_unavailable(module):
    from simontalk_api.main import create_app
    from simontalk_api.review_gateway import UnavailableReviewGateway

    app = create_app()
    try:
        assert type(app.state.review_gateway) is UnavailableReviewGateway
    finally:
        app.state.engine.dispose()


@pytest.mark.parametrize(
    "change",
    [
        {"choices": None},
        {"choices": []},
        {"choices": [{}, {}]},
        {"choices": [None]},
        {"choices": [{"index": 0, "finish_reason": "stop"}]},
        {"index": True},
        {"index": 1},
        {"finish_reason": None},
        {"message": None},
        {"message": {}},
        {"message": {"role": "user", "content": "{}"}},
        {"message": {"role": "assistant", "content": None}},
    ],
)
def test_malformed_chat_structure_is_unknown_never_retryable_output(module, change):
    data = envelope()
    if "choices" in change:
        data.update(change)
    else:
        data["choices"][0].update(change)
    gateway, calls, clients, stream = exchange(module, data)
    with pytest.raises(module.QwenReviewUnconfirmed) as caught:
        asyncio.run(gateway.generate(request()))
    assert caught.value.__context__ is None
    assert len(calls) == 1 and clients[0].is_closed and stream.closed


def test_missing_choices_is_unknown(module):
    data = envelope()
    del data["choices"]
    gateway, _, _, _ = exchange(module, data)
    with pytest.raises(module.QwenReviewUnconfirmed):
        asyncio.run(gateway.generate(request()))
