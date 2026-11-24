"""Compiled Flutter browser session, real Web Audio with Chromium's fake device."""

import asyncio
import json
import os
import socket
from pathlib import Path

import pytest
from fastapi import Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from test_authenticated_websocket_claim import SESSION
from test_authenticated_websocket_claim import browser_scope as browser_scope
from test_browser_media_loopback import running_browser
from test_practice_preparation import account as account
from test_qwen_turn_pump import msg
from test_qwen_turn_pump_supervisor import PumpSocket
from test_qwen_websocket_gateway import settings
from test_qwen_websocket_turn_policy import pcm
from test_websocket_supervisor_integration import check_unknown
from test_websocket_supervisor_integration import supervisor_scope as supervisor_scope

from simontalk_api.browser_media_socket import browser_media_router
from simontalk_api.qwen_websocket import QwenWebSocketGateway

# Observe real track and buffer-source lifecycles without retaining any samples.
OBSERVE = """
<script>
let tracks=[], starts=0, stops=0;
const media=navigator.mediaDevices;
const get=media.getUserMedia.bind(media);
media.getUserMedia=async c=>{
  const stream=await get(c); tracks.push(...stream.getTracks()); return stream;
};
const make=AudioContext.prototype.createBufferSource;
AudioContext.prototype.createBufferSource=function(){
  const node=make.call(this), start=node.start.bind(node), stop=node.stop.bind(node);
  node.start=(...args)=>{starts++;return start(...args);};
  node.stop=(...args)=>{stops++;return stop(...args);};
  return node;
};
window.mediaObservation=()=>JSON.stringify({tracks:tracks.map(t=>t.readyState),starts,stops});
window.simulatePageHide=()=>{
  Object.defineProperty(document,'hidden',{value:true,configurable:true});
  document.dispatchEvent(new Event('visibilitychange'));
};
</script>
"""


@pytest.mark.skipif(
    not (os.getenv("SIMONTALK_TEST_BROWSER") and os.getenv("SIMONTALK_FLUTTER_MEDIA_BUILD")),
    reason="requires Chromium and a built test/web/browser_media_loopback_entry.dart",
)
@pytest.mark.parametrize(
    ("ending", "reason"),
    [("account", "account_changed"), ("hidden", "background"), ("disconnect", "transport_closed")],
)
def test_flutter_media_session(factory, app, browser_scope, tmp_path, ending, reason):
    async def run():
        build = Path(os.environ["SIMONTALK_FLUTTER_MEDIA_BUILD"])
        _, row, _, _, proof = browser_scope
        result = asyncio.Future()

        class Voice(PumpSocket):
            speech = False

            async def send(self, raw):
                await super().send(raw)
                kind = self.sent[-1]["type"]
                if kind == "input_audio_buffer.append" and not self.speech:
                    self.speech = True
                    for idx, event in enumerate(("speech_started", "speech_stopped", "committed")):
                        self.incoming.put_nowait(
                            msg("input_audio_buffer." + event, f"e{idx}", item_id="u")
                        )
                    self.incoming.put_nowait(
                        msg(
                            "conversation.item.input_audio_transcription.completed",
                            "e3",
                            item_id="u",
                            content_index=0,
                            transcript="Hello",
                        )
                    )
                if kind == "response.create":
                    self.incoming.put_nowait(
                        msg("response.created", "e4", response={"id": "response_a"})
                    )
                    self.incoming.put_nowait(
                        msg(
                            "response.output_item.added",
                            "e5",
                            response_id="response_a",
                            output_index=0,
                            item={"id": "item_a", "type": "message", "role": "assistant"},
                        )
                    )
                    self.incoming.put_nowait(pcm())
                    self.incoming.put_nowait(
                        msg("input_audio_buffer.speech_started", "e8", item_id="other")
                    )

        voice = Voice()

        async def connect(*args, **kwargs):
            return voice

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            origin = f"http://127.0.0.1:{listener.getsockname()[1]}"
            app.state.settings = app.state.settings.model_copy(update={"allowed_origins": [origin]})
            app.include_router(
                browser_media_router(QwenWebSocketGateway(settings(), connector=connect))
            )

            @app.get("/")
            def page():
                html = (build / "index.html").read_text().replace("</head>", OBSERVE + "</head>")
                page = HTMLResponse(html)
                page.set_cookie("simontalk_session", SESSION, httponly=True)
                return page

            @app.get("/fixture")
            def fixture():
                return {
                    "account": json.loads(proof)["account_id"],
                    "connection": row,
                    "ending": ending,
                }

            @app.post("/disconnect")
            async def disconnect():
                voice.incoming.put_nowait(None)

            @app.post("/result")
            async def report(request: Request):
                data = await request.json()
                if not result.done():
                    result.set_result(data)

            app.mount("/", StaticFiles(directory=build))
            async with running_browser(
                app,
                listener,
                tmp_path,
                origin,
                "--autoplay-policy=no-user-gesture-required",
                "--use-fake-device-for-media-stream",
                "--use-fake-ui-for-media-stream",
                "--mute-audio",
            ):
                assert await asyncio.wait_for(result, 30) == {
                    "reason": reason,
                    "at_quarantine": {"tracks": ["live"], "starts": 1, "stops": 1},
                    "media": {"tracks": ["ended"], "starts": 1, "stops": 1},
                }
            check_unknown(factory, row)
            assert voice.speech and voice.close_calls == 1
            assert sum(m["type"] == "response.cancel" for m in voice.sent) == 1

    asyncio.run(run())
