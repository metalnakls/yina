#!/usr/bin/env python3
"""Opt-in integration test: isolated YINA, generated video, real CLI PiP entry.

YINA_RUN_APP_SMOKE=1 python3 other/tests/pip-app-startup-smoke.py
Only the subprocess launched here is quit/terminated. Existing players are not
controlled. Trace selection rejects ambiguity rather than using another session.
"""
import json
import os
import pathlib
import plistlib
import re
import socket
import subprocess
import tempfile
import time

if os.environ.get('YINA_RUN_APP_SMOKE') != '1':
    raise SystemExit('Set YINA_RUN_APP_SMOKE=1 to launch the isolated generated-video test.')
app = pathlib.Path(os.environ.get('YINA_TEST_APP', '/Applications/yina.app'))
version = str(plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleVersion'])
traces = pathlib.Path.home() / 'Library/Logs/tsmc.yina/PiPTransitions'
previous = set(traces.glob('*.jsonl'))
with tempfile.TemporaryDirectory(prefix='yina-pip-app-') as folder:
    folder = pathlib.Path(folder)
    video = folder / 'fixture.mkv'
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=640x360:rate=24:duration=5', '-c:v', 'libx264',
                    '-pix_fmt', 'yuv420p', '-y', str(video)], check=True)
    ipc = folder / 'mpv.sock'
    log_path = pathlib.Path(os.environ.get('YINA_APP_SMOKE_LOG', '/private/tmp/yina-pip-app-smoke.log'))
    with log_path.open('w') as output:
        process = subprocess.Popen([str(app / 'Contents/MacOS/yina'), '--clean-start', '--pip',
            '--mpv-input-ipc-server=' + str(ipc), '--mpv-loop-file=inf', '--mpv-ao=null',
            '--mpv-cache=no', str(video)], stdout=output, stderr=subprocess.STDOUT)
        connection = None
        try:
            deadline = time.monotonic() + 25
            while not ipc.exists() and time.monotonic() < deadline and process.poll() is None:
                time.sleep(0.1)
            assert process.poll() is None and ipc.exists(), f'No isolated IPC; see {log_path}'
            connection = socket.socket(socket.AF_UNIX)
            connection.settimeout(5)
            connection.connect(str(ipc))
            stream = connection.makefile('r')
            request_id = 0

            def command(args):
                global request_id
                request_id += 1
                connection.sendall((json.dumps({'command': args, 'request_id': request_id}) + '\n').encode())
                while True:
                    line = stream.readline()
                    assert line, 'Isolated IPC disconnected'
                    reply = json.loads(line)
                    if reply.get('request_id') == request_id:
                        return reply

            # Do not manually unpause: first-output readiness must release the
            # app's own load hold and begin playback by itself.
            while time.monotonic() < deadline:
                position = command(['get_property', 'time-pos']).get('data')
                if isinstance(position, (int, float)) and position >= 0.5:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError('Startup did not release playback hold')
            assert command(['get_property', 'pause']).get('data') is False
            assert command(['get_property', 'hwdec-current']).get('data') == 'videotoolbox'
            time.sleep(5)  # Allow the four-second automatic PiP trace to finish.
            captures = []
            for path in set(traces.glob('*.jsonl')) - previous:
                rows = [json.loads(line) for line in path.read_text().splitlines()]
                if any(row['event'] == 'begin' and f'build={version} ' in row['detail'] for row in rows):
                    captures.append((path, rows))
            assert len(captures) == 1, f'Ambiguous test trace selection: {len(captures)} captures'
            path, rows = captures[0]
            assert any(row['event'] == 'end' for row in rows), 'PiP trace did not finish'
            attached = [row for row in rows if (match := re.search(
                r'source=\{id=(\d+).*?videoHost=\{id=(\d+)', row['detail'])) and match[1] != match[2]]
            assert attached, 'Video never entered the actual PiP host'
            presented = [row for row in rows if row['event'] == 'drawable-presented'
                         and row['seconds'] > attached[0]['seconds']
                         and float(row['detail'].split('presented=')[-1]) > 0]
            assert len(presented) >= 10, 'Actual app PiP did not continue presenting frames'
            assert all('source={' not in row['detail'] or
                       re.search(r'source=\{[^}]*visible=false', row['detail']) for row in rows), \
                'Deferred CLI PiP entry revealed the source video window'
            print(f'PASS: isolated app pid={process.pid}, automatic unpause, direct VideoToolbox, '
                  f'actual PiP {len(presented)} presented frames, source remains hidden; trace={path.name}')
            command(['quit'])
            stream.close()
        finally:
            if connection is not None:
                connection.close()
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()  # Only the test child, never an existing player.
                process.wait(timeout=5)
