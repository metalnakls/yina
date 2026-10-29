"""Exercise the pinned audio driver's queue and notification transitions with fake renderers."""
from pathlib import Path
import subprocess
import tempfile

source = Path('build/metal-deps/sources/mpv/audio/out/ao_avfoundation.m').read_text()
header = source[source.index('@interface AVObserver'):source.index('static int64_t CMTimeGetNanoseconds')]
transitions = source[source.index('static void request_media_data'):source.index('static int control(')]
observer = source[source.index('@implementation AVObserver'):source.index('static int init(')]
body = (header + transitions + observer).replace('AVSampleBufferAudioRenderer', 'FakeRenderer').replace('AVSampleBufferRenderSynchronizer', 'FakeSync')
fixture = r'''#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
typedef void *CMAudioFormatDescriptionRef;
@interface FakeRenderer : NSObject
@property bool requesting;
@property int flushes;
- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(dispatch_block_t)block;
- (void)stopRequestingMediaData;
- (void)flush;
@end
@implementation FakeRenderer
- (void)requestMediaDataWhenReadyOnQueue:(dispatch_queue_t)queue usingBlock:(dispatch_block_t)block { self.requesting = YES; }
- (void)stopRequestingMediaData { self.requesting = NO; }
- (void)flush { self.flushes += 1; }
@end
@interface FakeSync : NSObject
@property float rate;
- (void)setRate:(float)rate;
@end
@implementation FakeSync
@end
struct ao { void *priv; };
static void feed(struct ao *ao) {}
#define MP_WARN(...) ((void)0)
'''+body+r'''
int main(void) { @autoreleasepool {
    static struct priv p = {0};
    static struct ao ao = {.priv=&p};
    p.queue = dispatch_queue_create("audio.fixture", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(p.queue, &queue_key, &queue_key, NULL);
    p.renderer = [FakeRenderer new];
    p.synchronizer = [FakeSync new];
    p.observer = [[AVObserver alloc] initWithAO:&ao];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:p.observer selector:@selector(handleRestartNotification:) name:@"reset" object:p.renderer];
    dispatch_sync(p.queue, ^{ start(&ao); });
    NSCAssert(p.renderer.requesting && p.synchronizer.rate == 1, @"start");
    set_pause(&ao, true);
    NSCAssert(!p.renderer.requesting && p.synchronizer.rate == 0, @"pause");
    dispatch_sync(p.queue, ^{ stop(&ao); start(&ao); });
    NSCAssert(p.paused && !p.renderer.requesting && p.synchronizer.rate == 0, @"reset preserves pause");
    dispatch_sync(p.queue, ^{ [center postNotificationName:@"reset" object:p.renderer]; });
    dispatch_sync(p.queue, ^{});
    NSCAssert(p.paused && !p.renderer.requesting && p.synchronizer.rate == 0, @"queue notification preserves pause");
    set_pause(&ao, false);
    NSCAssert(!p.paused && p.renderer.requesting && p.synchronizer.rate == 1, @"resume");
    dispatch_sync(p.queue, ^{ [center postNotificationName:@"reset" object:p.renderer]; });
    dispatch_sync(p.queue, ^{});
    NSCAssert(p.renderer.requesting && p.synchronizer.rate == 1, @"active reset restarts");
    [center removeObserver:p.observer];
    [p.observer invalidate];
    stop(&ao);
    NSCAssert(!p.renderer.requesting && p.synchronizer.rate == 0, @"stop");
    [center postNotificationName:@"reset" object:p.renderer];
    dispatch_sync(p.queue, ^{});
    NSCAssert(!p.renderer.requesting, @"late notification ignored");
    puts("PASS: production audio transitions preserve pause, avoid same-queue sync, and drain notifications");
} }
'''
with tempfile.TemporaryDirectory(prefix='yina-audio-state-') as directory:
    path = Path(directory)
    (path/'test.m').write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', str(path/'test.m'), '-framework', 'Foundation', '-o', str(path/'test')], check=True)
    subprocess.run([str(path/'test')], check=True, timeout=10)
