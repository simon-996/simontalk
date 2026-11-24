"""Real browser, loopback ASGI and PostgreSQL with synthetic input and provider."""

import asyncio
import json
import os
import socket
from contextlib import asynccontextmanager
from uuid import UUID

import pytest
import uvicorn
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from sqlalchemy import update
from test_authenticated_websocket_claim import CSRF, SESSION
from test_authenticated_websocket_claim import browser_scope as browser_scope
from test_practice_preparation import account as account
from test_qwen_turn_pump import msg
from test_qwen_turn_pump_supervisor import PumpSocket
from test_qwen_websocket_gateway import settings
from test_websocket_supervisor_integration import (
    check_unknown,
)
from test_websocket_supervisor_integration import (
    supervisor_scope as supervisor_scope,
)

from simontalk_api.browser_media_socket import browser_media_router
from simontalk_api.models import AuthSession
from simontalk_api.qwen_websocket import QwenWebSocketGateway
from simontalk_api.security import now


@asynccontextmanager
async def running_browser(host, listener, tmp_path, origin, *flags):
    server = uvicorn.Server(
        uvicorn.Config(
            host,
            host="127.0.0.1",
            port=listener.getsockname()[1],
            access_log=False,
            log_level="warning",
            ws_max_size=4096,
            ws_max_queue=4,
            lifespan="off",
        )
    )
    serving = asyncio.create_task(server.serve(sockets=[listener]))
    browser = None
    try:
        async with asyncio.timeout(3):
            while not server.started:
                await asyncio.sleep(0.01)
        browser = await asyncio.create_subprocess_exec(
            os.environ["SIMONTALK_TEST_BROWSER"],
            "--headless",
            "--no-first-run",
            "--disable-background-networking",
            "--disable-extensions",
            *flags,
            f"--user-data-dir={tmp_path / 'profile'}",
            origin,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        yield
    finally:
        server.should_exit = True
        if browser is not None and browser.returncode is None:
            browser.terminate()
            try:
                await asyncio.wait_for(browser.wait(), 4)
            except TimeoutError:
                browser.kill()
                await browser.wait()
        await asyncio.wait_for(serving, 5)


@pytest.mark.skipif(not os.getenv("SIMONTALK_TEST_BROWSER"), reason="requires Chromium executable")
@pytest.mark.parametrize("ending", ["stop", "revoke"])
def test_browser_media_loopback(factory, app, browser_scope, tmp_path, ending):
    async def run():
        prepared, row, auth_id, _, body = browser_scope
        delivered = asyncio.Event()
        client_result = asyncio.Future()

        class EchoSocket(PumpSocket):
            async def send(self, value):
                await super().send(value)
                if self.sent[-1]["type"] == "input_audio_buffer.append":
                    self.incoming.put_nowait(
                        msg("input_audio_buffer.speech_started", "e1", item_id="test_user")
                    )
                    delivered.set()

        provider = EchoSocket()
        opens = []

        async def connector(*args, **kwargs):
            opens.append(1)
            return provider

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            origin = f"http://127.0.0.1:{port}"
            host = FastAPI()
            host.state.session_factory = factory
            host.state.settings = app.state.settings.model_copy(
                update={"allowed_origins": [origin]}
            )
            host.state.practice_admission = app.state.practice_admission
            host.include_router(
                browser_media_router(QwenWebSocketGateway(settings(), connector=connector))
            )
            path = (
                f"/v1/practice-sessions/{prepared.session['id']}/connections/{row['id']}"
                f"/media/{row['client_instance_id']}/{row['epoch']}"
            )
            account_id = str(UUID(json.loads(body)["account_id"]))

            @host.get("/")
            async def page():
                html = """
                <script>
                const ws = new WebSocket("ws://"+location.host+PATH);
                const cookie = document.cookie.split("; ").find(s=>s.startsWith("simontalk_csrf="));
                const csrf = cookie.split("=")[1];
                let ready=0, events=0;
                ws.onopen=()=>ws.send(JSON.stringify({type:"authenticate",account_id:ACCOUNT,csrf}));
                ws.onmessage=e=>{
                  const m=JSON.parse(e.data);
                  if(m.kind==="ready"){
                    ready++;
                    ws.send(JSON.stringify({kind:"mode",epoch:1,muted:false}));
                    const frame=new DataView(new ArrayBuffer(3213));
                    frame.setUint8(0,1); frame.setUint32(1,1); frame.setBigUint64(5,1n);
                    ws.send(frame.buffer);
                  } else if(m.event?.item_id==="test_user"){
                    events++;
                    if(STOP) ws.send(JSON.stringify({kind:"stop"}));
                    else fetch("/revoke",{method:"POST"});
                  }
                };
                ws.onclose=e=>fetch("/result/"+e.code+"/"+ready+"/"+events,{method:"POST"});
                </script>"""
                response = HTMLResponse(
                    html.replace("PATH", json.dumps(path))
                    .replace("ACCOUNT", json.dumps(account_id))
                    .replace("STOP", json.dumps(ending == "stop"))
                )
                response.set_cookie("simontalk_session", SESSION, httponly=True)
                response.set_cookie("simontalk_csrf", CSRF)
                return response

            @host.post("/revoke")
            def revoke():
                with factory.begin() as db:
                    db.execute(
                        update(AuthSession)
                        .where(AuthSession.id == auth_id)
                        .values(revoked_at=now())
                    )

            @host.post("/result/{code}/{ready}/{events}")
            async def result(code: int, ready: int, events: int):
                if not client_result.done():
                    client_result.set_result((code, ready, events))

            async with running_browser(host, listener, tmp_path, origin):
                assert await asyncio.wait_for(client_result, 20) == (
                    1000 if ending == "stop" else 1011,
                    1,
                    1,
                )
                assert delivered.is_set() and len(opens) == provider.close_calls == 1
                check_unknown(factory, row)

    asyncio.run(run())
