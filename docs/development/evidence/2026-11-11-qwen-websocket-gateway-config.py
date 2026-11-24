import asyncio
import json
import os
import sys
from pathlib import Path

root = Path('/Users/simon/workplace/projects/simontalk')
sys.path.insert(0, str(root / 'services/api/src'))
from simontalk_api.qwen_config import load_qwen_realtime_settings
from simontalk_api.qwen_websocket import QwenWebSocketGateway, QwenWebSocketSettings

output = root / 'docs/development/evidence/2026-11-11-qwen-websocket-gateway-config.json'
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
report = {'status': 'started_unknown', 'connection_attempts': 0, 'session_created': False, 'model_matched': False, 'local_close_returned': False, 'response_requested': False, 'configuration_confirmed': False, 'usage': None}
with os.fdopen(fd, 'w') as f:
    json.dump(report, f)

async def main():
    socket = None
    try:
        private = load_qwen_realtime_settings(env_file=root / 'services/api/.env')
        settings = QwenWebSocketSettings(workspace_id=private.workspace_id, model='qwen3.8-omni-flash-realtime', config_id=private.config_id, api_key=private.api_key)
        config = {'provider':'dashscope','region':'cn-beijing','model':settings.model,'config_id':settings.config_id}
        attempt = QwenWebSocketGateway(settings).attempt(config)
        report['connection_attempts'] = 1
        socket = await attempt.open()
        raw = await asyncio.wait_for(socket.receive(), timeout=10)
        event = json.loads(raw)
        report['session_created'] = event.get('type') == 'session.created'
        report['model_matched'] = event.get('session',{}).get('model') == settings.model
        session_id = event.get('session', {}).get('id')
        if report['session_created'] and report['model_matched'] and isinstance(session_id, str) and session_id:
            await socket.send(json.dumps({'type': 'session.update', 'session': {'modalities': ['text', 'audio'], 'max_tokens': 64, 'enable_search': False, 'turn_detection': None, 'audio': {'output': {'voice': 'Tina', 'format': {'type': 'pcm', 'sample_rate': 24000}}}}}))
            configured = json.loads(await asyncio.wait_for(socket.receive(), timeout=10))
            session = configured.get('session', {})
            output_format = session.get('audio', {}).get('output', {}).get('format', {})
            report['configuration_confirmed'] = (configured.get('type') == 'session.updated' and session.get('id') == session_id and session.get('model') == settings.model and session.get('max_tokens') == 64 and output_format.get('type') == 'pcm' and output_format.get('sample_rate') == 24000)
        report['status'] = 'observed' if report['configuration_confirmed'] else 'unexpected_event'
    except Exception:
        report['status'] = 'failed_unknown'
    finally:
        if socket is not None:
            await socket.close()
            report['local_close_returned'] = True
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

asyncio.run(main())
print(json.dumps(report))
