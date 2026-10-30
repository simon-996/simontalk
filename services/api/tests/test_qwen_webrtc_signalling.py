import asyncio
import traceback
from dataclasses import FrozenInstanceError

import httpx
import pytest

from simontalk_api import qwen_webrtc_signalling as qwen
from simontalk_api.config import Settings
from simontalk_api.errors import APIError
from simontalk_api.main import create_app
from simontalk_api.practice import UnavailableAdmission
from simontalk_api.signalling import MAX_SDP_BYTES, UnavailableSignallingGateway

OFFER = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=private-offer-marker\r\nt=0 0\r\n"
ANSWER = b"v=0\r\no=- 2 2 IN IP4 127.0.0.1\r\ns=answer\r\nt=0 0\r\n"
SECRET = "sk-test-secret-marker"


def settings(**changes):
    return qwen.QwenWebRtcSettings(
        **{
            "workspace_id": "workspace-1",
            "model": "qwen3.5-omni-flash-realtime",
            "config_id": "candidate-v1",
            "api_key": SECRET,
            **changes,
        }
    )


def config(**changes):
    return {
        "provider": "dashscope",
        "region": "cn-beijing",
        "model": "qwen3.5-omni-flash-realtime",
        "config_id": "candidate-v1",
        **changes,
    }


class Body(httpx.AsyncByteStream):
    def __init__(self, chunks, *, stall=False, error=None):
        self.chunks = chunks
        self.stall = stall
        self.error = error
        self.closed = False
        self.reads = 0
        self.started = asyncio.Event()

    async def __aiter__(self):
        self.started.set()
        if self.stall:
            await asyncio.Future()
        if self.error is not None:
            raise self.error
        for chunk in self.chunks:
            self.reads += 1
            yield chunk

    async def aclose(self):
        self.closed = True


def exchange_factory(body=None, *, status=200, headers=None, handler=None):
    stream = Body([ANSWER]) if body is None else body
    calls, clients = [], []

    def factory():
        async def dispatch(request):
            calls.append(request)
            if handler is not None:
                return await handler(request)
            return httpx.Response(
                status,
                headers={"Content-Type": "application/sdp", **(headers or {})},
                stream=stream,
            )

        client = httpx.AsyncClient(transport=httpx.MockTransport(dispatch))
        clients.append(client)
        return client

    return stream, calls, clients, factory


def run(factory):
    return asyncio.run(
        qwen.QwenWebRtcSignallingGateway(settings(), client_factory=factory).exchange_offer(
            config(), OFFER
        )
    )


def test_configuration_is_silent_exact_and_secret_hidden():
    value = settings()
    gateway = qwen.QwenWebRtcSignallingGateway(value, client_factory=lambda: pytest.fail("I/O"))
    gateway.check_configuration(config())
    assert SECRET not in repr(value) + repr(gateway)
    with pytest.raises(FrozenInstanceError):
        value.workspace_id = "elsewhere"


@pytest.mark.parametrize(
    "workspace",
    [
        "",
        "-bad",
        "bad-",
        "a.b",
        "127.0.0.1",
        "host:443",
        "user@host",
        "host/path",
        "a%0db",
        "中",
        "UPPER",
        "a_b",
        "x" * 64,
        None,
        123,
    ],
)
def test_invalid_workspace_never_constructs_endpoint(workspace):
    with pytest.raises(ValueError):
        settings(workspace_id=workspace)


@pytest.mark.parametrize(
    "field,value",
    [
        ("model", "unknown"),
        ("model", "qwen3.5-omni-flash-realtime?x=y"),
        ("model", None),
        ("config_id", ""),
        ("config_id", "x/y"),
        ("config_id", "x" * 129),
        ("config_id", "中"),
        ("api_key", ""),
        ("api_key", " secret"),
        ("api_key", "x\r\ny"),
        ("api_key", "中"),
        ("api_key", "x" * 4097),
        ("api_key", None),
    ],
)
def test_invalid_local_settings_are_rejected_without_values_in_error(field, value):
    with pytest.raises(ValueError) as caught:
        settings(**{field: value})
    assert SECRET not in str(caught.value)


@pytest.mark.parametrize(
    "model",
    ["qwen3.5-omni-plus-realtime", "qwen3.5-omni-flash-realtime", "qwen3.8-omni-flash-realtime"],
)
def test_documented_models_accept_exact_matching_permit(model):
    qwen.QwenWebRtcSignallingGateway(settings(model=model)).check_configuration(config(model=model))


@pytest.mark.parametrize(
    "change",
    [
        {"provider": "other"},
        {"region": "ap-southeast-1"},
        {"model": "qwen3.5-omni-plus-realtime"},
        {"config_id": "candidate-v2"},
        {"endpoint": "https://other"},
    ],
)
def test_mismatched_permit_is_503_before_creating_client(change):
    gateway = qwen.QwenWebRtcSignallingGateway(
        settings(), client_factory=lambda: pytest.fail("I/O")
    )
    with pytest.raises(APIError) as caught:
        asyncio.run(gateway.exchange_offer(config(**change), OFFER))
    assert (caught.value.status, caught.value.code) == (503, "realtime_unavailable")


@pytest.mark.parametrize(
    "offer", ["", "not-sdp", "v=0\n\x00", "v=0\n" + "x" * MAX_SDP_BYTES, "v=0\n\ud800", None]
)
def test_invalid_offer_is_rejected_before_creating_client(offer):
    gateway = qwen.QwenWebRtcSignallingGateway(
        settings(), client_factory=lambda: pytest.fail("I/O")
    )
    with pytest.raises(APIError) as caught:
        asyncio.run(gateway.exchange_offer(config(), offer))
    assert caught.value.status == 422


def test_success_sends_fixed_url_headers_and_raw_offer_then_closes_everything():
    body, calls, clients, factory = exchange_factory(headers={"Content-Length": str(len(ANSWER))})
    assert run(factory) == ANSWER.decode()
    assert len(calls) == 1
    request = calls[0]
    assert request.method == "POST"
    assert str(request.url) == (
        "https://workspace-1.cn-beijing.maas.aliyuncs.com/api/v1/"
        "webrtc/realtime?model=qwen3.5-omni-flash-realtime"
    )
    assert request.content == OFFER.encode()
    assert request.headers["Authorization"] == f"Bearer {SECRET}"
    assert request.headers["Content-Type"] == "application/sdp"
    assert request.headers["Accept"] == "application/sdp"
    assert not {"cookie", "x-account-id", "x-csrf-token"} & set(request.headers)
    assert body.closed and clients[0].is_closed


@pytest.mark.parametrize("status", [201, 204, 301, 302, 307, 308, 400, 401, 429, 500, 503])
def test_non_200_never_reads_error_body_or_follows_redirect(status):
    body, calls, clients, factory = exchange_factory(
        status=status, headers={"Location": "https://other"}
    )
    with pytest.raises(qwen.QwenSignallingFailure):
        run(factory)
    assert len(calls) == 1 and body.reads == 0 and body.closed and clients[0].is_closed


@pytest.mark.parametrize(
    "headers",
    [
        {"Content-Type": "application/json"},
        {"Content-Type": ""},
        {"Content-Encoding": "gzip"},
        {"Content-Encoding": "br"},
        {"Content-Length": "-1"},
        {"Content-Length": "NaN"},
        {"Content-Length": "9999999999999999999999999"},
        {"Content-Length": str(MAX_SDP_BYTES + 1)},
    ],
)
def test_invalid_response_headers_rejected_before_reading(headers):
    body, calls, clients, factory = exchange_factory(headers=headers)
    with pytest.raises(qwen.QwenSignallingFailure):
        run(factory)
    assert len(calls) == 1 and body.reads == 0 and body.closed and clients[0].is_closed


@pytest.mark.parametrize(
    "raw,headers",
    [
        (b"", {}),
        (b"not-sdp", {}),
        (b"v=0\n\x00", {}),
        (b"v=0\n\xff", {}),
        (ANSWER, {"Content-Length": str(len(ANSWER) + 1)}),
        (ANSWER, {"Content-Length": str(len(ANSWER) - 1)}),
    ],
)
def test_invalid_answer_or_length_mismatch_closes_stream(raw, headers):
    body, _, clients, factory = exchange_factory(Body([raw]), headers=headers)
    with pytest.raises(qwen.QwenSignallingFailure):
        run(factory)
    assert body.closed and clients[0].is_closed


def test_incremental_raw_limit_stops_before_reading_remaining_body():
    body, calls, clients, factory = exchange_factory(
        Body([b"v=0\n", b"x" * MAX_SDP_BYTES, b"must-not-read"])
    )
    with pytest.raises(qwen.QwenSignallingFailure):
        run(factory)
    assert body.reads == 2 and body.closed and clients[0].is_closed and len(calls) == 1


def test_exact_byte_limit_and_sdp_parameter_mime_are_accepted():
    answer = b"v=0\n" + "字".encode() * 21844
    assert len(answer) == MAX_SDP_BYTES
    body, _, _, factory = exchange_factory(
        Body([answer[:4], answer[4:]]),
        headers={"Content-Type": "Application/SDP; charset=utf-8", "Content-Encoding": "identity"},
    )
    assert run(factory) == answer.decode()
    assert body.closed


def test_default_factory_disables_environment_redirects_and_retries(monkeypatch):
    real_client = httpx.AsyncClient
    options, transport_options, calls = [], [], []

    async def dispatch(request):
        calls.append(request)
        return httpx.Response(
            200, headers={"Content-Type": "application/sdp"}, stream=Body([ANSWER])
        )

    def transport(**kwargs):
        transport_options.append(kwargs)
        return httpx.MockTransport(dispatch)

    def client(**kwargs):
        options.append(kwargs)
        return real_client(**kwargs)

    monkeypatch.setenv("HTTPS_PROXY", "http://untrusted.invalid:8080")
    monkeypatch.setenv("SSL_CERT_FILE", "/nonexistent/environment-ca-file")
    monkeypatch.setattr(httpx, "AsyncHTTPTransport", transport)
    monkeypatch.setattr(httpx, "AsyncClient", client)
    result = asyncio.run(
        qwen.QwenWebRtcSignallingGateway(settings()).exchange_offer(config(), OFFER)
    )
    assert result == ANSWER.decode() and len(calls) == 1
    assert options[0]["trust_env"] is False and options[0]["follow_redirects"] is False
    assert transport_options == [{"trust_env": False, "retries": 0}]


def test_total_timeout_cancels_stalled_read_and_closes_stream(monkeypatch):
    monkeypatch.setattr(qwen, "_EXCHANGE_TIMEOUT_SECONDS", 0.01)
    body, calls, clients, factory = exchange_factory(Body([], stall=True))
    with pytest.raises(TimeoutError) as caught:
        run(factory)
    assert str(caught.value) == "Signalling exchange timed out"
    assert caught.value.__context__ is None
    assert body.closed and clients[0].is_closed and len(calls) == 1


def test_external_cancellation_is_not_converted_or_retried():
    async def exercise():
        body, calls, clients, factory = exchange_factory(Body([], stall=True))
        gateway = qwen.QwenWebRtcSignallingGateway(settings(), client_factory=factory)
        task = asyncio.create_task(gateway.exchange_offer(config(), OFFER))
        await body.started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert body.closed and clients[0].is_closed and len(calls) == 1

    asyncio.run(exercise())


@pytest.mark.parametrize(
    "error",
    [
        httpx.ReadError(f"{SECRET} {OFFER}"),
        RuntimeError(f"{SECRET} {OFFER}"),
        httpx.ReadTimeout(f"{SECRET} {OFFER}"),
    ],
)
def test_upstream_exception_is_fully_sanitized_without_context(error):
    body, calls, clients, factory = exchange_factory(Body([], error=error))
    expected = (
        TimeoutError if isinstance(error, httpx.TimeoutException) else qwen.QwenSignallingFailure
    )
    with pytest.raises(expected) as caught:
        run(factory)
    formatted = "".join(traceback.format_exception(caught.value))
    assert SECRET not in str(caught.value) + repr(caught.value) + formatted
    assert "private-offer-marker" not in formatted
    assert caught.value.__context__ is None
    assert body.closed and clients[0].is_closed and len(calls) == 1


def test_two_invocations_have_independent_closed_clients_and_no_internal_retry():
    async def exercise():
        streams, calls, clients = [], [], []

        def factory():
            body, current_calls, current_clients, create = exchange_factory()
            streams.append(body)
            client = create()
            calls.append(current_calls)
            clients.extend(current_clients)
            return client

        gateway = qwen.QwenWebRtcSignallingGateway(settings(), client_factory=factory)
        assert await gateway.exchange_offer(config(), OFFER) == ANSWER.decode()
        assert await gateway.exchange_offer(config(), OFFER) == ANSWER.decode()
        assert len(clients) == 2 and clients[0] is not clients[1]
        assert all(c.is_closed for c in clients) and all(s.closed for s in streams)
        assert [len(c) for c in calls] == [1, 1]

    asyncio.run(exercise())


def test_default_application_does_not_enable_candidate_even_with_environment_key(monkeypatch):
    monkeypatch.setenv("DASHSCOPE_API_KEY", SECRET)
    application = create_app(Settings(environment="test"))
    try:
        assert isinstance(application.state.practice_admission, UnavailableAdmission)
        assert isinstance(application.state.signalling_gateway, UnavailableSignallingGateway)
    finally:
        application.state.engine.dispose()
