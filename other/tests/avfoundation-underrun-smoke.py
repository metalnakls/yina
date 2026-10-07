"""Compile the pinned driver's actual callback/lifecycle with a scripted mpv buffer.
The real AVFoundation renderer stays muted; storage and yina are never opened.
"""
from pathlib import Path
import subprocess, tempfile, sys
source = Path('build/metal-deps/sources/mpv/audio/out/ao_avfoundation.m').read_text()
body = source[source.index('struct priv {'):source.index('static int control(')]
prelude = r'''
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
@class AVObserver;
struct ao { void *priv; int samplerate, sstride, available, reads, stops, reloads; bool eof, streaming; };
#define MPMAX(a,b) ((a) > (b) ? (a) : (b))
#define MP_FATAL(ao,...) ((void)0)
#define MP_VERBOSE(ao,...) ((void)0)
static int64_t mp_time_ns(void) { return (int64_t)clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int ao_read_data(struct ao *ao, void **data, int requested, int64_t time, bool *eof, bool pad, bool blocking) {
    ao->reads++;
    *eof = ao->eof;
    int n = MIN(requested, ao->available);
    ao->available -= n;
    memset(data[0], 0, n * ao->sstride);
    return n;
}
static void ao_stop_streaming(struct ao *ao) { ao->stops++; ao->streaming = false; }
static void ao_request_reload(struct ao *ao) { ao->reloads++; }
'''
main = r'''
int main(void) { @autoreleasepool {
    struct priv p = {0};
    struct ao ao = {.priv=&p, .samplerate=48000, .sstride=8};
    p.queue = dispatch_queue_create("fixture.audio", DISPATCH_QUEUE_SERIAL);
    p.renderer = [AVSampleBufferAudioRenderer new];
    p.renderer.muted = YES;
    p.synchronizer = [AVSampleBufferRenderSynchronizer new];
    [p.synchronizer addRenderer:p.renderer];
    AudioStreamBasicDescription asbd = {.mSampleRate=48000, .mFormatID=kAudioFormatLinearPCM,
        .mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,
        .mBytesPerPacket=8, .mFramesPerPacket=1, .mBytesPerFrame=8, .mChannelsPerFrame=2, .mBitsPerChannel=32};
    NSCAssert(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &p.format_description)==noErr, @"format");
    dispatch_sync(p.queue, ^{ ao.streaming=true; start(&ao); });
    [NSThread sleepForTimeInterval:0.1];
    __block int afterEmpty;
    dispatch_sync(p.queue, ^{ afterEmpty=ao.reads; NSCAssert(!ao.streaming && ao.stops==1, @"empty read stops requests"); });
    [NSThread sleepForTimeInterval:0.1];
    dispatch_sync(p.queue, ^{ NSCAssert(ao.reads==afterEmpty, @"empty renderer must not spin"); });
    dispatch_sync(p.queue, ^{ ao.available=4800; ao.streaming=true; start(&ao); });
    [NSThread sleepForTimeInterval:0.1];
    dispatch_sync(p.queue, ^{ NSCAssert(ao.available==0 && p.end_time_av>=0 && ao.reloads==0, @"returned data was enqueued"); });
    stop(&ao);
    dispatch_sync(p.queue, ^{ ao.available=4800; ao.streaming=true; start(&ao); });
    [NSThread sleepForTimeInterval:0.1];
    set_pause(&ao, true);
    dispatch_sync(p.queue, ^{ afterEmpty=ao.reads; });
    [NSThread sleepForTimeInterval:0.1];
    dispatch_sync(p.queue, ^{ NSCAssert(ao.reads==afterEmpty, @"pause stops callbacks"); ao.available=4800; });
    set_pause(&ao, false);
    [NSThread sleepForTimeInterval:0.1];
    dispatch_sync(p.queue, ^{ NSCAssert(ao.available==0 && ao.reads>afterEmpty, @"resume feeds returned data"); });
    stop(&ao);
    dispatch_sync(p.queue, ^{ ao.eof=true; ao.streaming=true; start(&ao); });
    [NSThread sleepForTimeInterval:0.1];
    dispatch_sync(p.queue, ^{ NSCAssert(!ao.streaming, @"EOF stops streaming"); });
    stop(&ao);
    dispatch_sync(p.queue, ^{ afterEmpty=ao.reads; });
    [NSThread sleepForTimeInterval:0.1];
    dispatch_sync(p.queue, ^{ NSCAssert(ao.reads==afterEmpty, @"shutdown stops callbacks"); });
    CFRelease(p.format_description);
    puts("PASS: actual mpv callback stops empty-read spinning; data return, pause/resume, EOF and shutdown");
} }
'''
# Keep AO/driver addresses stable across copied dispatch blocks.
main = main.replace('struct priv p =', 'static struct priv p =').replace('struct ao ao =', 'static struct ao ao =')
if '--baseline' in sys.argv:
    body = body.replace('if (eof || real_sample_count == 0)', 'if (eof)')
with tempfile.TemporaryDirectory(prefix='yina-audio-test-') as directory:
    path = Path(directory)
    (path/'test.m').write_text(prelude+body+main)
    subprocess.run(['xcrun','clang','-fobjc-arc','-Wno-unused-function',str(path/'test.m'),'-framework','AVFoundation','-framework','Foundation','-framework','CoreMedia','-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True,timeout=15)
