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

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSCAssert(argc == 2, @"supply the generated audio-only WAV fixture");
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
    puts("PASS: decoder failure cleanup and HDR pixel ownership (Address Sanitizer)");
  }
  return 0;
}
