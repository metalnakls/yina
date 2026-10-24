#!/usr/bin/env python3
"""Render generated fixtures only. Never launch yina or read personal media."""
import pathlib, subprocess, tempfile, struct, math, json
repo=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='yina-mpv-preview-') as directory:
    root=pathlib.Path(directory)
    base=['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','color=gray:size=320x180:rate=24:duration=2']
    subprocess.run(base+['-c:v','ffv1','-y',str(root/'sdr.mkv')],check=True)
    # Known neutral 100-nit PQ and 18%-scene HLG patches; no external media.
    normalized=100/10000
    pq=((3424/4096+(2413/128)*normalized**(2610/16384))/(1+(2392/128)*normalized**(2610/16384)))**(2523/32)
    hlg=0.17883277*math.log(12*0.18-0.28466892)+0.55991073
    for name,transfer,signal in [('pq','smpte2084',pq),('hlg','arib-std-b67',hlg)]:
        raw=root/f'{name}.yuv'
        raw.write_bytes(struct.pack('<H',round(64+876*signal))*(320*180)+struct.pack('<H',512)*(320*180//2))
        subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-stream_loop','-1','-f','rawvideo',
                        '-pixel_format','yuv420p10le','-video_size','320x180','-framerate','24','-i',str(raw),
                        '-t','2','-vf',f'setparams=range=limited:color_primaries=bt2020:color_trc={transfer}:colorspace=bt2020nc',
                        '-c:v','libx264','-crf','0','-preset','ultrafast','-y',str(root/f'{name}.mkv')],check=True)
        metadata=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','stream=color_transfer','-of','json',str(root/f'{name}.mkv')]))
        assert metadata['streams'][0]['color_transfer']==transfer, 'HDR fixture lost its transfer metadata'
    source=(repo/'yina/ThumbnailPeekView.swift').read_text()
    worker=root/'Worker.swift';worker.write_text('import Cocoa\n'+source[source.index('#if IINA_ENABLE_METAL_RENDERER\nimport Metal'):])
    main=root/'main.swift';main.write_text((repo/'other/tests/mpv-preview-smoke.swift').read_text())
    header=root/'mpv.h';header.write_text('#include <mpv/client.h>\n#include <mpv/render.h>\n#include <mpv/render_mtl.h>\n')
    binary=root/'probe'
    subprocess.run(['xcrun','swiftc','-D','IINA_ENABLE_METAL_RENDERER','-module-cache-path','/private/tmp/yina-event-module-cache',
                    '-I',str(repo/'deps/include'),'-import-objc-header',str(header),str(worker),str(main),
                    str(repo/'deps/lib/libmpv.2.dylib'),'-Xlinker','-rpath','-Xlinker',str(repo/'deps/lib'),'-o',str(binary)],check=True)
    subprocess.run([str(binary),str(root)],check=True,timeout=90)
