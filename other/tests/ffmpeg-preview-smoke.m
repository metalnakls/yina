#import <Cocoa/Cocoa.h>
#import <libavutil/frame.h>
#import <libavutil/imgutils.h>
#import <libavutil/pixfmt.h>
#import <libproc.h>
#import "FFmpegController.h"
#import "YINA-Swift.h"

@implementation FFmpegLogger
+ (void)debug:(NSString *)message {}
+ (void)error:(NSString *)message {}
+ (void)warn:(NSString *)message {}
@end

@interface FFmpegController (Testing)
- (int)getPeeksForFile:(NSString *)file thumbnailsWidth:(int)width requestedTime:(double)time operation:(NSOperation *)operation;
- (void)saveThumbnail:(AVFrame *)frame width:(int)width height:(int)height index:(int)index realTime:(int)time forFile:(NSString *)file;
@end

static int descriptorCount(void) {
  return proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0) / (int)sizeof(struct proc_fdinfo);
}

@interface PreviewConsumer : NSObject <FFmpegControllerDelegate>
@property NSArray<FFThumbnail *> *results;
@property BOOL succeeded;
@end
@implementation PreviewConsumer
- (void)didUpdateThumbnails:(NSArray<FFThumbnail *> *)thumbnails forFile:(NSString *)filename withProgress:(NSInteger)progress {}
- (void)didGenerateThumbnails:(NSArray<FFThumbnail *> *)thumbnails forFile:(NSString *)filename succeeded:(BOOL)succeeded {
  self.results = thumbnails;
  self.succeeded = succeeded;
}
@end

@interface ControlledPreview : FFmpegController
@property dispatch_semaphore_t entered;
@property dispatch_semaphore_t proceed;
@end
@implementation ControlledPreview
- (instancetype)init {
  if ((self = [super init])) {
    _entered = dispatch_semaphore_create(0);
    _proceed = dispatch_semaphore_create(0);
  }
  return self;
}
- (int)getPeeksForFile:(NSString *)file thumbnailsWidth:(int)width requestedTime:(double)time operation:(NSOperation *)operation {
  [[self valueForKey:@"thumbnails"] addObject:[FFThumbnail new]];
  dispatch_semaphore_signal(self.entered);
  dispatch_semaphore_wait(self.proceed, DISPATCH_TIME_FOREVER);
  return 0;
}
@end

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSCAssert(argc == 3, @"supply the generated audio and video fixtures");
    FFmpegController *controller = [FFmpegController new];
    NSBlockOperation *operation = [NSBlockOperation new];
    NSString *fixture = [NSString stringWithUTF8String:argv[1]];
    [controller getPeeksForFile:fixture thumbnailsWidth:240 requestedTime:NAN operation:operation];
    int before = descriptorCount();
    for (int i = 0; i < 100; i++) {
      @autoreleasepool {
        NSCAssert([controller getPeeksForFile:fixture thumbnailsWidth:240 requestedTime:NAN operation:operation] < 0,
                  @"an audio-only file has no preview stream");
      }
    }
    NSCAssert(descriptorCount() <= before + 2, @"decoder errors must close their input files");

    AVFrame *frame = av_frame_alloc();
    frame->format = AV_PIX_FMT_RGBA64LE;
    frame->width = frame->height = 16;
    frame->color_trc = AVCOL_TRC_SMPTE2084;
    NSCAssert(av_frame_get_buffer(frame, 1) >= 0, @"allocate HDR fixture");
    for (int y = 0; y < 16; y++) {
      uint16_t *row = (uint16_t *)(frame->data[0] + y * frame->linesize[0]);
      for (int x = 0; x < 16; x++) { row[x*4] = row[x*4+1] = row[x*4+2] = 32768; row[x*4+3] = 65535; }
    }
    [controller saveThumbnail:frame width:16 height:16 index:0 realTime:0 forFile:fixture];
    av_frame_free(&frame);
    FFThumbnail *thumbnail = [[controller valueForKey:@"thumbnails"] firstObject];
    CGImageRef image = [thumbnail.image CGImageForProposedRect:NULL context:nil hints:nil];
    NSCAssert(image != NULL, @"HDR image exists after decoder buffers are freed");
    CFDataRef imageData = CGDataProviderCopyData(CGImageGetDataProvider(image));
    const uint8_t *pixels = CFDataGetBytePtr(imageData);
    // This read is instrumented by ASan; the provider must own surviving pixels.
    NSCAssert(pixels[3] == 255 && pixels[0] > 0, @"HDR image pixels survive their producer");
    CFRelease(imageData);
    __weak FFThumbnail *releasedThumbnail = thumbnail;
    [controller cancelThumbnailGeneration];
    NSOperationQueue *queue = [controller valueForKey:@"queue"];
    [queue waitUntilAllOperationsAreFinished];
    NSCAssert([[controller valueForKey:@"thumbnails"] count] == 0, @"cancel releases worker results");
    NSCAssert([thumbnail.image CGImageForProposedRect:NULL context:nil hints:nil] != NULL,
              @"consumer's retained thumbnail survives worker cleanup");
    thumbnail = nil;
    NSCAssert(releasedThumbnail == nil, @"cancelled worker must not retain a decoded frame");

    PreviewConsumer *consumer = [PreviewConsumer new];
    controller.delegate = consumer;
    [controller generateThumbnailForFile:[NSString stringWithUTF8String:argv[2]] atTime:0 thumbWidth:64];
    [queue waitUntilAllOperationsAreFinished];
    NSCAssert(consumer.succeeded && consumer.results.count > 0, @"successful preview reaches consumer");
    NSCAssert([[controller valueForKey:@"thumbnails"] count] == 0 &&
              [[controller valueForKey:@"thumbnailPartialResult"] count] == 0 &&
              [[controller valueForKey:@"addedTimestamps"] count] == 0,
              @"completed worker releases full and partial results");
    FFThumbnail *delivered = consumer.results.firstObject;
    NSCAssert([delivered.image CGImageForProposedRect:NULL context:nil hints:nil] != NULL,
              @"delivered image survives producer cleanup");
    ControlledPreview *cancelled = [ControlledPreview new];
    PreviewConsumer *cancelledConsumer = [PreviewConsumer new];
    cancelled.delegate = cancelledConsumer;
    [cancelled generateThumbnailForFile:fixture thumbWidth:64];
    NSCAssert(dispatch_semaphore_wait(cancelled.entered, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
              @"decode operation started");
    [cancelled cancelThumbnailGeneration];
    dispatch_semaphore_signal(cancelled.proceed);
    [[cancelled valueForKey:@"queue"] waitUntilAllOperationsAreFinished];
    NSCAssert(cancelledConsumer.results == nil, @"cancelled decode must not deliver a completion");
    NSCAssert([[cancelled valueForKey:@"thumbnails"] count] == 0, @"in-flight cancellation releases decoded results");
    puts("PASS: decoder failure cleanup, HDR pixel ownership, cancellation release, completed preview delivery and release (Address Sanitizer)");
  }
  return 0;
}
