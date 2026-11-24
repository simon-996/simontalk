import asyncio
import base64
import json
import re
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path('/Users/simon/workplace/projects/simontalk')
sys.path.insert(0, str(ROOT / 'services/api/src'))
from simontalk_api.qwen_config import load_qwen_realtime_settings
from websockets.asyncio.client import connect

nonce = secrets.token_urlsafe(24)
lock = threading.Lock()
used = False

async def capture():
    settings = load_qwen_realtime_settings(env_file=ROOT / 'services/api/.env')
    if not re.fullmatch(r'llm-[a-z0-9]{1,64}', settings.workspace_id):
        raise ValueError('invalid_config')
    url = f'wss://{settings.workspace_id}.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen3.8-omni-flash-realtime'
    events=[]; total_bytes=0; response_id=None; item_id=None; usage=None; status=None
    async with asyncio.timeout(30):
        async with connect(url, additional_headers={'Authorization':'Bearer '+settings.api_key}, open_timeout=7, close_timeout=5, max_size=128*1024, compression=None, proxy=None, ping_interval=None) as ws:
            async def next_type(kind):
                for _ in range(100):
                    obj=json.loads(await ws.recv())
                    if obj.get('type') == 'error': raise ValueError('provider_error')
                    if obj.get('type') == kind: return obj
                raise ValueError('event_limit')
            created=await next_type('session.created')
            if created.get('session',{}).get('model') != 'qwen3.8-omni-flash-realtime': raise ValueError('wrong_model')
            await ws.send(json.dumps({'type':'session.update','session':{'modalities':['text','audio'],'max_tokens':64,'enable_search':False,'turn_detection':None,'audio':{'input':{'format':{'type':'pcm','sample_rate':16000,'sample_format':'s16le','channels':1,'packing':'interleaved','channel_layout':'mono'}},'output':{'voice':'Tina','format':{'type':'pcm','sample_rate':24000}}}}}))
            updated=await next_type('session.updated')
            session=updated.get('session',{})
            if session.get('id') != created['session'].get('id') or session.get('model') != 'qwen3.8-omni-flash-realtime' or session.get('max_tokens') != 64: raise ValueError('configuration_unconfirmed')
            output=session.get('audio',{}).get('output',{}).get('format',{})
            if output.get('type') != 'pcm' or output.get('sample_rate') != 24000: raise ValueError('format_unconfirmed')
            await ws.send(json.dumps({'type':'conversation.item.create','item':{'type':'message','role':'user','content':[{'type':'input_text','text':'Say hello in one short sentence.'}]}}))
            await next_type('conversation.item.created')
            await ws.send('{"type":"response.create"}')
            for _ in range(500):
                obj=json.loads(await ws.recv()); kind=obj.get('type')
                if kind=='error': raise ValueError('provider_error')
                if kind=='response.created':
                    if response_id is not None: raise ValueError('extra_response')
                    response_id=obj.get('response',{}).get('id')
                    if not isinstance(response_id,str) or not response_id: raise ValueError('response_invalid')
                elif kind=='response.output_item.added':
                    item=obj.get('item',{})
                    if obj.get('response_id') != response_id or item_id is not None or item.get('type')!='message' or item.get('role')!='assistant': raise ValueError('item_invalid')
                    item_id=item.get('id')
                elif kind=='response.audio.delta':
                    if obj.get('response_id')!=response_id or obj.get('item_id')!=item_id or len(events)>=256: raise ValueError('audio_identity')
                    decoded=base64.b64decode(obj['delta'], validate=True); total_bytes+=len(decoded)
                    if total_bytes>480000 or not decoded or len(decoded)%2: raise ValueError('audio_limit')
                    events.append({k:obj.get(k) for k in ('type','event_id','response_id','item_id','output_index','content_index','delta')})
                elif kind=='response.done':
                    response=obj.get('response',{})
                    if response.get('id')!=response_id: raise ValueError('response_mismatch')
                    status=response.get('status'); raw=response.get('usage')
                    if isinstance(raw,dict):
                        usage={k:raw[k] for k in ('input_tokens','output_tokens','total_tokens') if isinstance(raw.get(k),int) and not isinstance(raw.get(k),bool) and raw[k]>=0}
                    break
            else: raise ValueError('event_limit')
    if status!='completed' or not events: raise ValueError('incomplete')
    return {'events':events,'status':status,'bytes':total_bytes,'usage':usage}

PAGE = '''<!doctype html><meta charset="utf-8"><title>真实音频事件检查</title>
<h1>真实音频事件检查</h1><p>一次固定文本请求，输出经零增益静音，不使用麦克风，不保存音频。</p>
<button id="run">运行一次</button><pre id="out">尚未运行</pre>
<script src="/streaming_pcm_output.js"></script><script>
document.querySelector('#run').addEventListener('click', async (ev) => {
 ev.currentTarget.disabled=true; const out=document.querySelector('#out'), result={}; let ctx,router;
 try {
  ctx=new AudioContext(); await ctx.resume(); const gain=ctx.createGain(); gain.gain.value=0; gain.connect(ctx.destination);
  const wrapped=new Proxy(ctx,{get(target,key){if(key==='destination') return gain; const value=Reflect.get(target,key,target); return typeof value==='function'?value.bind(target):value;}});
  const r=await fetch('/capture',{method:'POST',headers:{'Content-Type':'application/json','X-Probe-Nonce':'NONCE'}});
  if(!r.ok) throw Error('capture_failed'); const data=await r.json();
  router=window.simontalkStreamingPcmOutput.createResponseRouter(wrapped,24000);
  const first=data.events[0]; result.chunks=data.events.length; result.total_bytes=data.bytes; result.status=data.status; result.usage=data.usage;
  result.started=router.start(first.response_id,first.item_id); result.appended=0; result.rejected=0;
  for(const event of data.events) {const answer=router.appendQwenDelta(event); if(answer==='appended') result.appended++; else {result.rejected++; break;}}
  result.stopped=router.stop(first.response_id); router.dispose(); await ctx.close(); result.context=ctx.state;
 } catch (_) {router?.dispose(); if(ctx && ctx.state!=='closed') await ctx.close().catch(()=>{}); result.error='probe_failed';}
 out.textContent=JSON.stringify(result,null,2);
});</script>'''.replace('NONCE',nonce).encode()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def send(self, code, data, content='application/json'):
        self.send_response(code); self.send_header('Content-Type',content); self.send_header('Content-Length',str(len(data))); self.send_header('Cache-Control','no-store'); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path=='/': self.send(200,PAGE,'text/html; charset=utf-8')
        elif self.path=='/streaming_pcm_output.js': self.send(200,(ROOT/'apps/client/web/streaming_pcm_output.js').read_bytes(),'text/javascript')
        else: self.send(404,b'{}')
    def do_POST(self):
        global used
        if self.path!='/capture' or self.headers.get('X-Probe-Nonce')!=nonce or self.headers.get('Origin')!='http://127.0.0.1:7395': self.send(403,b'{}'); return
        with lock:
            if used: self.send(429,b'{}'); return
            used=True
        try: data=asyncio.run(capture()); self.send(200,json.dumps(data).encode())
        except Exception: self.send(502,b'{"error":"capture_failed"}')

print('Local probe ready on 127.0.0.1:7395, max one exchange',flush=True)
ThreadingHTTPServer(('127.0.0.1',7395),Handler).serve_forever()
