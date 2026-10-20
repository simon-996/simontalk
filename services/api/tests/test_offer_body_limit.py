import asyncio
import json

import pytest
from starlette.responses import JSONResponse


def invoke(
    events,
    *,
    headers=(),
    method="POST",
    path="/v1/practice-sessions/p/connections/c/offer",
    delay=0,
    send_delay=0,
):
    from simontalk_api.offer_body_limit import ConnectionBodyLimitMiddleware

    sent, consumed = [], []
    messages = list(events)

    async def receive():
        if delay:
            await asyncio.sleep(delay)
        return messages.pop(0) if messages else {"type": "http.disconnect"}

    async def app(scope, receive, send):
        message = await receive()
        consumed.append(message.get("body", b""))
        await JSONResponse({"size": len(consumed[-1])})(scope, receive, send)

    async def send(message):
        sent.append(message)
        if send_delay:
            await asyncio.sleep(send_delay)

    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "headers": list(headers),
        "state": {"request_id": "test-request"},
    }
    asyncio.run(ConnectionBodyLimitMiddleware(app)(scope, receive, send))
    status = next((m["status"] for m in sent if m["type"] == "http.response.start"), None)
    body = b"".join(m.get("body", b"") for m in sent if m["type"] == "http.response.body")
    return status, json.loads(body) if body else None, consumed


def test_chunked_body_is_reassembled_once_without_trusting_length():
    status, result, consumed = invoke(
        [
            {"type": "http.request", "body": b"abc", "more_body": True},
            {"type": "http.request", "body": b"def", "more_body": False},
        ],
        headers=[(b"content-length", b"1")],
    )
    assert status == 200 and result == {"size": 6}
    assert consumed == [b"abcdef"]


def test_streaming_over_limit_never_reaches_application():
    status, result, consumed = invoke(
        [
            {"type": "http.request", "body": b"x" * (96 * 1024), "more_body": True},
            {"type": "http.request", "body": b"y", "more_body": False},
        ]
    )
    assert status == 413 and result["code"] == "request_too_large"
    assert result["request_id"] == "test-request"
    assert consumed == []


def test_size_rejection_does_not_turn_into_second_response_when_send_is_slow(monkeypatch):
    from simontalk_api import offer_body_limit

    monkeypatch.setattr(offer_body_limit, "BODY_TIMEOUT_SECONDS", 0.01)
    status, result, consumed = invoke(
        [{"type": "http.request", "body": b"x" * (97 * 1024)}], send_delay=0.02
    )
    assert status == 413 and result["code"] == "request_too_large"
    assert consumed == []


def test_slow_total_body_deadline_is_bounded(monkeypatch):
    from simontalk_api import offer_body_limit

    monkeypatch.setattr(offer_body_limit, "BODY_TIMEOUT_SECONDS", 0.01)
    status, result, consumed = invoke([{"type": "http.request", "body": b"x"}], delay=0.1)
    assert status == 408 and result["code"] == "request_timeout"
    assert consumed == []


def test_disconnect_during_body_never_enters_parser():
    status, _, consumed = invoke([{"type": "http.disconnect"}])
    assert status is None and consumed == []


def test_limit_does_not_read_unrelated_route_body():
    status, result, consumed = invoke(
        [{"type": "http.request", "body": b"x" * (97 * 1024)}], path="/v1/auth/login"
    )
    assert status == 200 and result["size"] == 97 * 1024
    assert len(consumed) == 1


def test_observation_chunks_have_an_independent_eight_kibibyte_limit():
    status, result, consumed = invoke(
        [
            {"type": "http.request", "body": b"x" * 8192, "more_body": True},
            {"type": "http.request", "body": b"y", "more_body": False},
        ],
        path="/v1/practice-sessions/p/connections/c/observations",
        headers=[(b"content-length", b"1")],
    )
    assert status == 413 and result["code"] == "request_too_large"
    assert consumed == []


def test_observation_body_receipt_has_the_same_total_deadline(monkeypatch):
    from simontalk_api import offer_body_limit

    monkeypatch.setattr(offer_body_limit, "BODY_TIMEOUT_SECONDS", 0.01)
    status, result, consumed = invoke(
        [{"type": "http.request", "body": b"x"}],
        path="/v1/practice-sessions/p/connections/c/observations",
        delay=0.1,
    )
    assert status == 408 and result["code"] == "request_timeout"
    assert consumed == []


@pytest.mark.parametrize("suffix", ["offer", "observations", "transcripts"])
def test_http_size_error_keeps_cors_request_id_and_never_echoes_body(client, suffix):
    response = client.post(
        f"/v1/practice-sessions/p/connections/c/{suffix}",
        content=b"private-body" * 25000,
        headers={"Origin": "http://localhost:7357", "Content-Type": "application/json"},
    )
    assert response.status_code == 413
    assert response.headers["Access-Control-Allow-Origin"] == "http://localhost:7357"
    assert response.headers["Cache-Control"] == "no-store"
    assert response.json()["request_id"] == response.headers["X-Request-ID"]
    assert "private-body" not in response.text


def test_transcript_stream_has_independent_256_kibibyte_limit():
    status, result, consumed = invoke(
        [
            {"type": "http.request", "body": b"x" * (256 * 1024), "more_body": True},
            {"type": "http.request", "body": b"y", "more_body": False},
        ],
        path="/v1/practice-sessions/p/connections/c/transcripts",
    )
    assert status == 413 and result["code"] == "request_too_large"
    assert consumed == []


def test_transcript_body_receipt_has_total_deadline(monkeypatch):
    from simontalk_api import offer_body_limit

    monkeypatch.setattr(offer_body_limit, "BODY_TIMEOUT_SECONDS", 0.01)
    status, result, consumed = invoke(
        [{"type": "http.request", "body": b"x"}],
        path="/v1/practice-sessions/p/connections/c/transcripts",
        delay=0.1,
    )
    assert status == 408 and result["code"] == "request_timeout"
    assert consumed == []
