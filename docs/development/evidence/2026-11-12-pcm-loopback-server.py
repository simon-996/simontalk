import asyncio
import base64
import functools
import http.server
import json
import pathlib
import threading

from websockets.asyncio.server import serve
from simontalk_api.qwen_pcm_upstream import QwenPcmInput
from simontalk_api.websocket_pcm_relay import WebSocketPcmRelay
from simontalk_api.websocket_pcm_wire import decode_pcm_frame

ROOT = pathlib.Path('/tmp/simontalk-pcm-loopback')

class Server(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def log_message(self, *_):
        pass

class FakeProvider:
    def __init__(self):
        self.frames = 0
        self.bytes = 0
        self.closed = 0
    async def send(self, value):
        data=json.loads(value)
        if data.get('type') != 'input_audio_buffer.append':
            raise ValueError('unexpected type')
        pcm=base64.b64decode(data['audio'], validate=True)
        if len(pcm) != 3200:
            raise ValueError('unexpected length')
        self.frames += 1
        self.bytes += len(pcm)
    async def close(self):
        self.closed += 1

async def session(ws):
    upstream=FakeProvider()
    relay=WebSocketPcmRelay(QwenPcmInput(upstream))
    report={'status':'started','modes':[], 'forwarded_by_epoch':{}, 'dropped':0, 'stop':False, 'error':False}
    try:
        async for message in ws:
            result=await relay.accept(message)
            if isinstance(message,str):
                control=json.loads(message)
                if result == 'mode': report['modes'].append([control['epoch'],control['muted']])
                elif result == 'stopped': report['stop']=True; break
            elif result == 'forwarded':
                epoch=str(decode_pcm_frame(message).epoch)
                report['forwarded_by_epoch'][epoch]=report['forwarded_by_epoch'].get(epoch,0)+1
            else: report['dropped']+=1
    except Exception:
        report['error']=True
    finally:
        await relay.close()
        report.update(status='finished', provider_frames=upstream.frames, provider_bytes=upstream.bytes, provider_closed=upstream.closed)
        temp=ROOT/'result.tmp'
        temp.write_text(json.dumps(report))
        temp.replace(ROOT/'result.json')

async def main():
    handler=functools.partial(Server,directory=str(ROOT))
    server=http.server.ThreadingHTTPServer(('127.0.0.1',18765),handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    async with serve(session,'127.0.0.1',18766,origins=['http://127.0.0.1:18765'],max_size=4096,max_queue=4):
        print('ready',flush=True)
        await asyncio.Future()

asyncio.run(main())
