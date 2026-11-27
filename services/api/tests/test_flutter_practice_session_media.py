"""Compiled SimonTalkApp live /practice/session over real Chrome and PostgreSQL."""

import asyncio
import base64
import os
import socket
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from fastapi import Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.testclient import TestClient
from sqlalchemy import select
from test_assistance import TestGateway as TestAssistanceGateway
from test_authenticated_websocket_claim import SESSION
from test_browser_media_loopback import running_browser
from test_practice_preparation import account as account
from test_qwen_turn_pump import msg
from test_qwen_turn_pump_supervisor import PumpSocket
from test_qwen_websocket_gateway import CONFIG, settings
from test_qwen_websocket_turn_policy import pcm
from test_rehearsal_preparations import release as release_source
from test_saved_transcripts import event as transcript_event
from test_saved_transcripts import seal as seal_practice
from test_saved_transcripts import successful_review

from simontalk_api.browser_media_socket import browser_media_router
from simontalk_api.main import create_app
from simontalk_api.models import (
    AssistanceAttempt,
    AssistanceJob,
    AuthSession,
    ConnectionObservation,
    FinalTranscript,
    PracticeCompletion,
    PracticeSession,
    RealtimeConnection,
    ReviewJob,
    TerminationCheck,
    User,
    UserPreferences,
    VoiceResponseUsage,
)
from simontalk_api.qwen_websocket import QwenWebSocketGateway
from simontalk_api.review_gateway import ReviewCapability, ReviewGeneration, ReviewUsage
from simontalk_api.review_worker import run_review_batch
from simontalk_api.security import SESSION_SECONDS, digest, now

DRIVER = """
<script>
let tracks=[], starts=0, stops=0, naturalEnds=0, settled=[];
const contexts=[];
let outputClockHeld=false, clockMeasurements=0;
const wsSend=WebSocket.prototype.send;
WebSocket.prototype.send=function(data){
  if(typeof data==='string'){
    try{
      const parsed=JSON.parse(data);
      if(parsed?.kind==='settled') settled.push(parsed.response_id);
    }catch(_){}
  }
  return wsSend.call(this, data);
};
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
  node.addEventListener('ended',()=>{naturalEnds++;});
  return node;
};
const snapshot=()=>({tracks:tracks.map(t=>t.readyState),starts,stops,settled:[...settled]});
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const texts=()=>window.simontalkSessionTest?JSON.parse(window.simontalkSessionTest.texts()):[];
async function waitText(target){
  for(let i=0;i<600;i++){
    if(texts().includes(target)) return;
    await sleep(30);
  }
  throw new Error('timeout_text:'+target+':'+JSON.stringify(texts()));
}
async function waitSettled(responseId){
  for(let i=0;i<600;i++){
    if(settled.includes(responseId)) return;
    await sleep(20);
  }
  throw new Error('timeout_settled:'+responseId+':'+JSON.stringify(settled));
}
async function tap(label){
  for(let i=0;i<600;i++){
    if(window.simontalkSessionTest?.tap(label)){
      await sleep(50);
      return;
    }
    await sleep(30);
  }
  throw new Error('timeout_tap:'+label+':'+JSON.stringify(texts()));
}
window.addEventListener('load', async ()=>{
  const post=body=>fetch('/test-result',{
    method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)
  });
  try{
    const {
      scenario,
      sourceSessionId,
      exactQuote,
      suggestion,
    }=await (await fetch('/test-scenario')).json();
    if(scenario==='playback_overlap_no_clock'){
      Object.defineProperty(AudioContext.prototype,'getOutputTimestamp',{value:undefined});
    }
    if(scenario==='microphone_interrupted'||scenario==='output_suspended'){
      const NativeAudioContext=window.AudioContext;
      window.AudioContext=class extends NativeAudioContext{
        constructor(options){super(options);contexts.push(this);}
      };
    }
    if(scenario==='multi_turn_end_save'){
      const originalClock=AudioContext.prototype.getOutputTimestamp;
      if(typeof originalClock!=='function') throw new Error('missing_output_clock');
      outputClockHeld=true;
      AudioContext.prototype.getOutputTimestamp=function(){
        const reading=originalClock.call(this);
        clockMeasurements++;
        return outputClockHeld ? {...reading,contextTime:0} : reading;
      };
    }
    if(scenario==='rehearsal_end_save'){
      await waitText('今天，聊点日常。');
      location.hash='#/practice/'+sourceSessionId+'/review';
      await waitText('本次表达建议');
      await tap('练这一句');
      await waitText('本次重练目标');
      await tap('深入表达');
      await tap('确认并准备');
      await waitText('已登记重练准备');
      await tap('进入重练通话');
      await waitText('重练：这一句表达');
      await waitText('本次难度：深入表达');
      await waitText('重练片段：'+exactQuote);
      await waitText('参考说法：'+suggestion);
      await waitText('正在听你说');
      const activeMedia=snapshot();
      await waitText('I really enjoy learning English.');
      await waitText('Hi learner');
      await waitSettled('response_a');
      await tap('结束并复盘');
      const drainMedia=snapshot();
      await waitText('本次练习已结束');
      await waitText('已保存，仍有内容缺失');
      await waitText('查看重练评价');
      await tap('查看本次记录');
      await waitText('这次练习的保存情况');
      const rehearsalVoiceLine='已记录 1 次回复 · 已知输入 12 Token（文本 0 / 音频 0） · '
        +'已知输出 4 Token（文本 0 / 音频 0）';
      await tap('查看本次用量');
      await waitText(rehearsalVoiceLine);
      await tap('返回练习详情');
      await waitText('查看重练评价');
      await tap('查看重练评价');
      await waitText('尚未整理建议');
      await tap('整理表达建议');
      await waitText('建议已排队');
      await fetch('/run-review-worker',{method:'POST'});
      await tap('刷新复盘状态');
      await waitText('本次重练评价');
      await waitText('本次已传达原意');
      await waitText('本次已展示目标表达');
      if(texts().includes('练这一句')) throw new Error('nested_rehearsal_exposed');
      location.hash='#/account';
      await waitText('练习偏好');
      await tap('查看本人用量');
      await waitText('逐句重练语音');
      await waitText(rehearsalVoiceLine);
      await waitText('已记录 2 次尝试 · 已知输入 20 Token · 已知输出 8 Token');
      await post({
        ok:true,
        activeMedia,
        overlapMedia:null,
        drainMedia,
        finalMedia:snapshot(),
        texts:texts(),
      });
      return;
    }
    if(scenario==='daily_topic_end_save'){
      await tap('周末计划');
      await waitText('分享一个周末安排');
      if(snapshot().tracks.length) throw new Error('topic_preparation_opened_microphone');
      await tap('开始语音练习');
      await waitText('周末计划');
      await waitText('正在听你说');
      await waitText('中文提示');
      await waitText('分享一个周末安排');
      const activeMedia=snapshot();
      await tap('字幕：开');
      await tap('给我一个英文开头');
      await waitText('One thing I like about it is...');
      await tap('关闭提示');
      await waitText('字幕已关闭，可随时在右上角打开。');
      await tap('给我一个英文开头');
      await waitText('One thing I like about it is...');
      await tap('关闭提示');
      await tap('字幕：关');
      await fetch('/trigger-next-turn',{method:'POST'});
      await waitText('I plan to read on Saturday.');
      await waitText('What will you read?');
      if(texts().includes('中文提示')) throw new Error('opening_hint_outlived_first_turn');
      await waitSettled('response_a');
      await fetch('/wait-final-turns');
      await tap('字幕：开');
      await tap('逐句翻译');
      await waitText('选择要翻译的话轮');
      await tap('What will you read?');
      await waitText('你打算读什么？');
      await waitText('字幕已关闭，可随时在右上角打开。');
      await tap('关闭提示');
      await tap('字幕：关');
      await tap('结束并复盘');
      const drainMedia=snapshot();
      await waitText('本次练习已结束');
      location.hash='#/history';
      await waitText('练习记录');
      await tap('周末计划');
      await waitText('这次练习');
      await waitText('分享一个周末安排');
      location.hash='#/account';
      await waitText('练习偏好');
      await tap('查看本人用量');
      await waitText('主动求助');
      await waitText('已记录 2 次尝试 · 已知输入 27 Token · 已知输出 15 Token');
      await post({ok:true,activeMedia,drainMedia,finalMedia:snapshot(),texts:texts()});
      return;
    }
    await tap('开始自由聊天');
    await tap('开始准备');
    await tap('进入通话');
    await waitText('正在听你说');
    const activeMedia=snapshot();
    if(scenario==='leave'){
      await fetch('/wait-upstream-pcm');
      window.simontalkSessionTest.popRoute();
      await waitText('准备一次自由聊天');
      for(let i=0;i<100&&snapshot().tracks.includes('live');i++) await sleep(20);
      await post({ok:true,activeMedia,finalMedia:snapshot(),texts:texts()});
      return;
    }
    if(scenario==='microphone_interrupted'||scenario==='output_suspended'){
      const [input, output]=contexts;
      if(input?.state!=='running'||output?.state!=='running') throw new Error('media_not_running');
      if(scenario==='microphone_interrupted'){
        await waitText('正在说');
        Object.defineProperty(tracks[0],'muted',{value:true});
        tracks[0].dispatchEvent(new Event('mute'));
        await waitText('麦克风输入已中断，本次练习已停止。');
      }else{
        await waitSettled('response_a');
        await waitText('正在听你说');
        await output.suspend();
        await waitText('语音播放失败，本次练习已停止。');
      }
      for(let i=0;i<100&&contexts.some(context=>context.state!=='closed');i++) await sleep(20);
      let currentConnection;
      for(let i=0;i<100;i++){
        const response=await fetch('/v1/practice-sessions/current');
        if(!response.ok) throw new Error('current_practice_failed');
        currentConnection=(await response.json()).connection;
        if(currentConnection?.status==='unknown') break;
        await sleep(30);
      }
      if(texts().includes('已停止收音，等待保存回执')) throw new Error('unrequested_save_receipt');
      await tap('查看本次记录');
      await waitText('这次练习的保存情况');
      await waitText('仍有连接与用量待核对。文字保存不会解除连接占用。');
      await post({ok:true,activeMedia,finalMedia:snapshot(),
        contextStates:contexts.map(context=>context.state),
        currentStatus:currentConnection?.status,texts:texts()});
      return;
    }
    let overlapMedia=null;
    if(scenario==='drain_tail'){
      await waitText('One last thing');
      await tap('结束并复盘');
    }else if(scenario==='explicit_takeover_interrupt'){
      await waitText('Hello from call');
      await waitText('正在说');
      await waitText('我来说');
      await tap('静音麦克风');
      await waitText('我来说（先开启麦克风）');
      await tap('打开麦克风');
      await waitText('我来说');
      overlapMedia=snapshot();
      await tap('我来说');
      await waitText('对话已中断，暂时无法继续');
      await fetch('/trigger-next-turn',{method:'POST'});
      await waitText('Let me take over');
      await tap('结束并复盘');
    }else if(scenario.startsWith('playback_overlap')){
      await waitText('Hello from call');
      await waitText('Hi learner');
      overlapMedia=snapshot();
      await fetch('/trigger-next-turn',{method:'POST'});
      await waitText('对话已中断，暂时无法继续');
      await waitText('Let me interrupt');
      await tap('结束并复盘');
    }else{
      await waitText('Hello from call');
      await waitText('Hi learner');
      for(let i=0;i<300&&naturalEnds===0;i++) await sleep(20);
      if(naturalEnds!==1) throw new Error('missing_graph_end');
      await sleep(90);
      if(settled.includes('response_a') || clockMeasurements<2){
        throw new Error('settled_before_device_output');
      }
      outputClockHeld=false;
      await waitSettled('response_a');
      await tap('说慢一点');
      await waitText('本场已放慢语速');
      await fetch('/trigger-next-turn',{method:'POST'});
      await waitText('Second question');
      await waitText('Second answer');
      await waitSettled('response_b');
      await tap('静音麦克风');
      await waitText('麦克风已关闭');
      await waitText('打开麦克风');
      await tap('打开麦克风');
      await waitText('正在听你说');
      await tap('静音麦克风');
      await waitText('麦克风已关闭');
      await tap('结束并复盘');
    }
    const drainMedia=snapshot();
    await waitText('本次练习已结束');
    if(scenario!=='drain_tail') await waitText('已保存，仍有内容缺失');
    await waitText('查看本次记录');
    await tap('查看本次记录');
    await waitText('这次练习的保存情况');
    if(scenario==='multi_turn_end_save'){
      const usageLine='已记录 2 次回复 · 已知输入 12 Token（文本 0 / 音频 0） · '
        +'已知输出 4 Token（文本 0 / 音频 0）';
      await tap('查看本次用量');
      await waitText('本次语音回复');
      await waitText(usageLine);
      await waitText('另有 1 次回复缺少总用量（不计作零）。');
      location.hash='#/account';
      await waitText('练习偏好');
      await tap('查看本人用量');
      await waitText('普通练习语音');
      await waitText(usageLine);
      await waitText('仍有 1 条语音连接终止状态待核对，可能存在尚未入账的上游用量。');
    }
    await post({
      ok:true,
      activeMedia,
      overlapMedia,
      drainMedia,
      finalMedia:snapshot(),
      texts:texts(),
    });
  }catch(err){
    await post({ok:false,error:String(err),media:snapshot(),texts:texts()});
  }
});
</script>
"""


def _seed_web_account(factory, app, account):
    identity, _ = account
    user_id = UUID(identity["user"]["id"])
    with factory.begin() as db:
        user = db.get(User, user_id)
        db.add(
            AuthSession(
                user_id=user.id,
                token_digest=digest(SESSION),
                platform="web",
                expires_at=now() + timedelta(seconds=SESSION_SECONDS),
            )
        )

    class Admission:
        def admit(self, uid):
            return SimpleNamespace(**CONFIG)

    app.state.practice_admission = Admission()
    return user_id


def _queue_user_turn(incoming, prefix, item_id, transcript):
    for idx, event in enumerate(("speech_started", "speech_stopped", "committed")):
        incoming.put_nowait(msg("input_audio_buffer." + event, f"{prefix}_{idx}", item_id=item_id))
    incoming.put_nowait(
        msg(
            "conversation.item.input_audio_transcription.completed",
            f"{prefix}_done",
            item_id=item_id,
            content_index=0,
            transcript=transcript,
        )
    )


@pytest.mark.skipif(
    not (os.getenv("SIMONTALK_TEST_BROWSER") and os.getenv("SIMONTALK_FLUTTER_SESSION_BUILD")),
    reason="requires Chromium and a built test/web/practice_session_browser_entry.dart",
)
@pytest.mark.parametrize(
    "scenario",
    [
        "multi_turn_end_save",
        "daily_topic_end_save",
        "rehearsal_end_save",
        "explicit_takeover_interrupt",
        "playback_overlap",
        "playback_overlap_no_clock",
        "leave",
        "drain_tail",
        "microphone_interrupted",
        "output_suspended",
    ],
)
def test_flutter_practice_session_page(factory, app, account, tmp_path, scenario):
    build = Path(os.environ["SIMONTALK_FLUTTER_SESSION_BUILD"])
    user_id = _seed_web_account(factory, app, account)
    source_info = {"sourceSessionId": None, "exactQuote": None, "suggestion": None}
    rehearsal_review_gateway = None
    assistance_gateway = None
    if scenario == "daily_topic_end_save":
        assistance_gateway = app.state.assistance_gateway = TestAssistanceGateway()
    if scenario == "rehearsal_end_save":
        identity, headers = account
        seed_app = create_app(app.state.settings)
        seed_app.state.practice_admission = app.state.practice_admission
        try:
            with TestClient(seed_app) as seed_client:
                parent_resp = seed_client.post(
                    "/v1/practice-sessions",
                    headers={**headers, "Idempotency-Key": str(uuid4())},
                    json={"mode": "free_chat"},
                )
                assert parent_resp.status_code == 201
                parent_scope = SimpleNamespace(
                    identity=identity, headers=headers, session=parent_resp.json()
                )
                _, parent_completion = seal_practice(
                    seed_client,
                    parent_scope,
                    [transcript_event(text="I enjoy English. 我喜欢英语。")],
                )
                parent_job = successful_review(
                    seed_client, parent_scope, parent_completion, factory
                )
                parent_item = parent_job["result"]["items"][0]
                release_source(factory, SimpleNamespace(scope=parent_scope))
                source_info = {
                    "sourceSessionId": parent_scope.session["id"],
                    "exactQuote": parent_item["exact_quote"],
                    "suggestion": parent_item["suggestion"],
                }
        finally:
            seed_app.state.engine.dispose()

        class RehearsalEvalGateway:
            capability = ReviewCapability("rehearsal-e2e-v1", False)

            async def generate(self, request):
                target = request.targets[0]
                evidence = {
                    key: target[key]
                    for key in ("source_connection_id", "source_turn_id", "revision")
                }
                evidence["exact_quote"] = target["text"]
                return ReviewGeneration(
                    [],
                    usage=ReviewUsage(input_tokens=20, output_tokens=8),
                    rehearsal_evaluation={
                        "schema_version": "rehearsal_evaluation_v1",
                        "target_hash": request.rehearsal_target["target_hash"],
                        "intent": {
                            "status": "conveyed",
                            "explanation": "已清楚表达喜欢学英语的原意。",
                            "evidence": [evidence],
                        },
                        "target_issue": {
                            "status": "demonstrated",
                            "explanation": "自然使用了目标表达。",
                            "evidence": [evidence],
                        },
                    },
                )

        rehearsal_review_gateway = RehearsalEvalGateway()
        app.state.review_gateway = rehearsal_review_gateway

    async def run():
        pcm_arrived = asyncio.Event()
        result = asyncio.Future()
        offer_requests = 0
        playback_overlap = scenario.startswith("playback_overlap")
        explicit_takeover = scenario == "explicit_takeover_interrupt"
        long_pcm = base64.b64encode(b"\x00\x00" * 18000).decode("ascii")

        class Voice(PumpSocket):
            speech = False
            responses = 0

            async def send(self, raw):
                await super().send(raw)
                kind = self.sent[-1]["type"]
                if kind == "input_audio_buffer.append" and not self.speech:
                    self.speech = True
                    pcm_arrived.set()
                    if scenario == "drain_tail":
                        self.incoming.put_nowait(
                            msg("input_audio_buffer.speech_started", "u1_0", item_id="u1")
                        )
                        self.incoming.put_nowait(
                            msg(
                                "conversation.item.input_audio_transcription.delta",
                                "u1_delta",
                                item_id="u1",
                                content_index=0,
                                text="One last ",
                                stash="thing",
                            )
                        )
                    elif scenario == "rehearsal_end_save":
                        _queue_user_turn(
                            self.incoming, "u1", "u1", "I really enjoy learning English."
                        )
                    elif scenario not in {"leave", "daily_topic_end_save"}:
                        _queue_user_turn(self.incoming, "u1", "u1", "Hello from call")
                if kind == "input_audio_buffer.commit" and scenario == "drain_tail":
                    self.incoming.put_nowait(
                        msg("input_audio_buffer.committed", "u1_2", item_id="u1")
                    )
                    self.incoming.put_nowait(
                        msg(
                            "conversation.item.input_audio_transcription.completed",
                            "u1_done",
                            item_id="u1",
                            content_index=0,
                            transcript="One last thing.",
                        )
                    )
                if kind == "response.create":
                    self.responses += 1
                    if self.responses == 1:
                        self.incoming.put_nowait(
                            msg("response.created", "r1_c", response={"id": "response_a"})
                        )
                        self.incoming.put_nowait(
                            msg(
                                "response.output_item.added",
                                "r1_o",
                                response_id="response_a",
                                output_index=0,
                                item={"id": "item_a", "type": "message", "role": "assistant"},
                            )
                        )
                        if (
                            playback_overlap
                            or explicit_takeover
                            or scenario == "microphone_interrupted"
                        ):
                            for idx in range(3):
                                self.incoming.put_nowait(
                                    msg(
                                        "response.audio.delta",
                                        f"r1_pcm_{idx}",
                                        response_id="response_a",
                                        item_id="item_a",
                                        output_index=0,
                                        content_index=0,
                                        delta=long_pcm,
                                    )
                                )
                        else:
                            self.incoming.put_nowait(pcm("r1_pcm"))
                        self.incoming.put_nowait(
                            msg(
                                "response.audio_transcript.done",
                                "r1_t",
                                response_id="response_a",
                                item_id="item_a",
                                output_index=0,
                                content_index=0,
                                transcript="What will you read?"
                                if scenario == "daily_topic_end_save"
                                else "Hi learner",
                            )
                        )
                        if not explicit_takeover:
                            self.incoming.put_nowait(
                                msg(
                                    "response.done",
                                    "r1_d",
                                    response={
                                        "id": "response_a",
                                        "status": "completed",
                                        "usage": {"input_tokens": 12, "output_tokens": 4},
                                    },
                                )
                            )
                    elif self.responses == 2:
                        self.incoming.put_nowait(
                            msg("response.created", "r2_c", response={"id": "response_b"})
                        )
                        self.incoming.put_nowait(
                            msg(
                                "response.output_item.added",
                                "r2_o",
                                response_id="response_b",
                                output_index=0,
                                item={"id": "item_b", "type": "message", "role": "assistant"},
                            )
                        )
                        self.incoming.put_nowait(
                            msg(
                                "response.audio.delta",
                                "r2_pcm",
                                response_id="response_b",
                                item_id="item_b",
                                output_index=0,
                                content_index=0,
                                delta="AAA=",
                            )
                        )
                        self.incoming.put_nowait(
                            msg(
                                "response.audio_transcript.done",
                                "r2_t",
                                response_id="response_b",
                                item_id="item_b",
                                output_index=0,
                                content_index=0,
                                transcript="Second answer",
                            )
                        )
                        self.incoming.put_nowait(
                            msg(
                                "response.done",
                                "r2_d",
                                response={"id": "response_b", "status": "completed"},
                            )
                        )
                if kind == "response.cancel" and explicit_takeover:
                    self.incoming.put_nowait(
                        msg(
                            "response.done",
                            "r1_cancel",
                            response={"id": "response_a", "status": "cancelled"},
                        )
                    )

        voice = Voice()

        async def connect(*args, **kwargs):
            return voice

        class CountingSignallingGateway:
            def exchange_offer(self, *args, **kwargs):
                nonlocal offer_requests
                offer_requests += 1
                raise AssertionError("WebSocket session must never call SDP signalling")

        app.state.signalling_gateway = CountingSignallingGateway()

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
                html = (build / "index.html").read_text().replace("</head>", DRIVER + "</head>")
                response = HTMLResponse(html)
                response.set_cookie("simontalk_session", SESSION, httponly=True)
                return response

            @app.get("/test-scenario")
            def read_scenario():
                return {"scenario": scenario, **source_info}

            @app.post("/run-review-worker")
            async def trigger_review_worker():
                assert rehearsal_review_gateway is not None

                def has_active_job():
                    with factory() as db:
                        return any(
                            job.status in {"queued", "running"}
                            for job in db.scalars(select(ReviewJob))
                        )

                processed = 0
                async with asyncio.timeout(8):
                    while True:
                        processed += await run_review_batch(factory, rehearsal_review_gateway)
                        if not await asyncio.to_thread(has_active_job):
                            break
                        await asyncio.sleep(0.05)
                return {"processed": processed}

            @app.get("/wait-upstream-pcm")
            async def wait_upstream_pcm():
                await asyncio.wait_for(pcm_arrived.wait(), 15)
                return {"ok": True}

            @app.get("/wait-final-turns")
            async def wait_final_turns():
                def count():
                    with factory() as db:
                        return len(db.scalars(select(FinalTranscript)).all())

                async with asyncio.timeout(8):
                    while await asyncio.to_thread(count) < 2:
                        await asyncio.sleep(0.05)
                return {"ok": True}

            @app.post("/trigger-next-turn")
            async def trigger_next_turn():
                if scenario == "daily_topic_end_save":
                    await asyncio.wait_for(pcm_arrived.wait(), 10)
                    _queue_user_turn(voice.incoming, "u1", "u1", "I plan to read on Saturday.")
                elif scenario == "multi_turn_end_save":
                    await asyncio.sleep(0.05)
                    _queue_user_turn(voice.incoming, "u2", "u2", "Second question")
                elif explicit_takeover:
                    _queue_user_turn(voice.incoming, "u2", "u2", "Let me take over")
                else:
                    _queue_user_turn(voice.incoming, "u2", "u2", "Let me interrupt")
                return {"ok": True}

            @app.post("/test-result")
            async def report(request: Request):
                data = await request.json()
                if not result.done():
                    result.set_result(data)
                return {"ok": True}

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
                outcome = await asyncio.wait_for(result, 45)
                assert outcome["ok"] is True, outcome

        assert offer_requests == 0
        expected_updates = 2 if scenario == "multi_turn_end_save" else 1
        assert sum(m["type"] == "session.update" for m in voice.sent) == expected_updates
        if scenario == "multi_turn_end_save":
            updates = [m for m in voice.sent if m["type"] == "session.update"]
            assert "natural conversational pace" in updates[0]["session"]["instructions"]
            assert "Speak slowly and clearly." in updates[1]["session"]["instructions"]
            types = [m["type"] for m in voice.sent]
            assert (
                types.index("response.create")
                < max(idx for idx, kind in enumerate(types) if kind == "session.update")
                < max(idx for idx, kind in enumerate(types) if kind == "response.create")
            )
        expected_cancels = 1 if explicit_takeover else 0
        assert sum(m["type"] == "response.cancel" for m in voice.sent) == expected_cancels
        assert voice.speech and voice.close_calls == 1
        assert outcome["activeMedia"]["tracks"] == ["live"]
        assert outcome["finalMedia"]["tracks"] == ["ended"]

        with factory() as db:
            practices = list(
                db.scalars(
                    select(PracticeSession)
                    .where(PracticeSession.user_id == user_id)
                    .order_by(PracticeSession.created_at)
                )
            )
            if scenario == "daily_topic_end_save":
                assert len(practices) == 1
                (live_practice,) = practices
                assert live_practice.kind == "ordinary" and live_practice.mode == "daily_topic"
                assert live_practice.configuration["topic"]["id"] == "weekend_plans"
                assert "Talk about weekend plans" in voice.sent[0]["session"]["instructions"]
                assert len(assistance_gateway.sources) == 2
                assert assistance_gateway.sources[0].turns == ()
                assert "weekend plans" in assistance_gateway.sources[0].topic
                assert assistance_gateway.sources[1].text == "What will you read?"
                jobs = {
                    job.kind: job
                    for job in db.scalars(
                        select(AssistanceJob).where(AssistanceJob.session_id == live_practice.id)
                    )
                }
                starter_job = jobs["english_starter"]
                assert starter_job.attempt_count == 1
                starter_usage = db.get(AssistanceAttempt, (starter_job.id, 1))
                assert (starter_usage.input_tokens, starter_usage.output_tokens) == (12, 8)
                translation_job = jobs["translation"]
                assert translation_job.source_turn_revision == 1
                assert translation_job.result == "你打算读什么？"
            elif scenario == "rehearsal_end_save":
                preflight, live_practice = practices
                assert preflight.kind == "ordinary" and preflight.status == "completed"
                assert live_practice.kind == "rehearsal"
                assert str(live_practice.source_session_id) == source_info["sourceSessionId"]
                assert live_practice.configuration["effective_difficulty"] == "advanced"
                sent_instructions = voice.sent[0]["session"]["instructions"]
                assert "helping the learner rehearse one expression" in sent_instructions
                assert "richer detail" in sent_instructions
                assert source_info["exactQuote"] in sent_instructions
                assert source_info["suggestion"] in sent_instructions
            else:
                preflight, live_practice = practices
                assert preflight.status == "cancelled"
            live_connection = db.scalar(
                select(RealtimeConnection).where(RealtimeConnection.session_id == live_practice.id)
            )
            assert live_connection is not None
            assert (live_connection.status, live_connection.termination_status) == (
                "unknown",
                "unknown",
            )
            check = db.get(TerminationCheck, live_connection.id)
            assert check is not None and check.status == "blocked" and check.attempts == 0
            usage = list(
                db.scalars(
                    select(VoiceResponseUsage).where(
                        VoiceResponseUsage.connection_id == live_connection.id
                    )
                )
            )
            if scenario == "multi_turn_end_save":
                prefs = db.get(UserPreferences, user_id)
                assert prefs is not None and prefs.speech_pace == "normal"
                assert live_practice.configuration["preferences"]["speech_pace"] == "normal"
                assert {(item.input_tokens, item.output_tokens) for item in usage} == {
                    (12, 4),
                    (None, None),
                }
            elif playback_overlap or scenario in {
                "rehearsal_end_save",
                "daily_topic_end_save",
                "microphone_interrupted",
                "output_suspended",
            }:
                assert [(item.input_tokens, item.output_tokens) for item in usage] == [(12, 4)]
            elif explicit_takeover:
                assert [(item.input_tokens, item.output_tokens) for item in usage] == [(None, None)]
            else:
                assert usage == []

            completion = db.get(PracticeCompletion, live_practice.id)
            if scenario == "leave":
                assert live_practice.status == "interrupted"
                assert completion is None
            elif scenario in {"microphone_interrupted", "output_suspended"}:
                assert outcome["contextStates"] == ["closed", "closed"]
                assert outcome["currentStatus"] == "unknown"
                assert live_practice.status == "interrupted"
                assert completion is None
                assert voice.responses == 1
                assert all(m["type"] != "input_audio_buffer.commit" for m in voice.sent)
                if scenario == "microphone_interrupted":
                    assert outcome["finalMedia"]["stops"] >= 1
                    assert outcome["finalMedia"]["settled"] == []
                else:
                    assert outcome["finalMedia"]["stops"] == 0
                    assert outcome["finalMedia"]["settled"] == ["response_a"]
            elif scenario in {"rehearsal_end_save", "daily_topic_end_save"}:
                assert outcome["drainMedia"]["tracks"] == ["ended"]
                assert outcome["finalMedia"]["starts"] == 1
                assert outcome["finalMedia"]["stops"] == 0
                assert outcome["finalMedia"]["settled"] == ["response_a"]
                assert sum(m["type"] == "response.create" for m in voice.sent) == 1
                assert live_practice.status == "completed"
                assert live_practice.state_reason == "input_sealed"
                assert completion is not None and completion.status == "sealed"
                transcripts = list(
                    db.scalars(
                        select(FinalTranscript)
                        .where(FinalTranscript.connection_id == live_connection.id)
                        .order_by(FinalTranscript.sequence)
                    )
                )
                user_text = (
                    "I really enjoy learning English."
                    if scenario == "rehearsal_end_save"
                    else "I plan to read on Saturday."
                )
                assistant_text = (
                    "Hi learner" if scenario == "rehearsal_end_save" else "What will you read?"
                )
                assert [(t.turn_index, t.role, t.text) for t in transcripts] == [
                    (1, "user", user_text),
                    (2, "assistant", assistant_text),
                ]
            elif scenario == "drain_tail":
                assert outcome["drainMedia"]["tracks"] == ["ended"]
                assert outcome["finalMedia"]["starts"] == 0
                assert voice.responses == 0
                assert sum(m["type"] == "input_audio_buffer.commit" for m in voice.sent) == 1
                assert live_practice.status == "completed"
                assert completion is not None and completion.status == "sealed"
                transcripts = list(
                    db.scalars(
                        select(FinalTranscript).where(
                            FinalTranscript.connection_id == live_connection.id
                        )
                    )
                )
                assert [(t.role, t.text) for t in transcripts] == [("user", "One last thing.")]
            elif playback_overlap or explicit_takeover:
                assert outcome["drainMedia"]["tracks"] == ["ended"]
                assert outcome["overlapMedia"]["starts"] == 3
                assert outcome["overlapMedia"]["settled"] == []
                assert outcome["finalMedia"]["starts"] == 3
                assert outcome["finalMedia"]["stops"] >= 2
                assert outcome["finalMedia"]["settled"] == []
                assert sum(m["type"] == "response.create" for m in voice.sent) == 1
                assert live_practice.status == "completed"
                assert live_practice.state_reason == "input_sealed"
                assert completion is not None and completion.status == "sealed"
                transcripts = list(
                    db.scalars(
                        select(FinalTranscript)
                        .where(FinalTranscript.connection_id == live_connection.id)
                        .order_by(FinalTranscript.sequence)
                    )
                )
                third_text = "Let me take over" if explicit_takeover else "Let me interrupt"
                assert [(t.turn_index, t.role, t.text) for t in transcripts] == [
                    (1, "user", "Hello from call"),
                    (2, "assistant", "Hi learner"),
                    (3, "user", third_text),
                ]
            else:
                assert outcome["drainMedia"]["tracks"] == ["ended"]
                assert outcome["finalMedia"]["starts"] == 2
                assert outcome["finalMedia"]["stops"] == 0
                assert outcome["finalMedia"]["settled"] == ["response_a", "response_b"]
                assert sum(m["type"] == "response.create" for m in voice.sent) == 2
                assert live_practice.status == "completed"
                assert live_practice.state_reason == "input_sealed"
                assert completion is not None and completion.status == "sealed"
                transcripts = list(
                    db.scalars(
                        select(FinalTranscript)
                        .where(FinalTranscript.connection_id == live_connection.id)
                        .order_by(FinalTranscript.sequence)
                    )
                )
                assert [(t.turn_index, t.role, t.text) for t in transcripts] == [
                    (1, "user", "Hello from call"),
                    (2, "assistant", "Hi learner"),
                    (3, "user", "Second question"),
                    (4, "assistant", "Second answer"),
                ]
                observed = list(
                    db.scalars(
                        select(ConnectionObservation.code)
                        .where(ConnectionObservation.connection_id == live_connection.id)
                        .order_by(ConnectionObservation.sequence)
                    )
                )
                for expected in (
                    "negotiating",
                    "transport_connected",
                    "configuration_confirmed",
                    "requesting_microphone",
                    "microphone_active",
                    "playback_waiting",
                    "playback_playing",
                    "muted",
                    "unmuted",
                    "local_closed",
                ):
                    assert expected in observed, observed

    asyncio.run(run())
