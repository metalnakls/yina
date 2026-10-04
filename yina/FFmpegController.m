//
//  FFmpegController.m
//  yina
//
//  Created by lhc on 9/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

#import "FFmpegController.h"
#import <Accelerate/Accelerate.h>
#import <Cocoa/Cocoa.h>
#import <math.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libswscale/swscale.h>
#import <libavutil/imgutils.h>
#import <libavutil/mastering_display_metadata.h>
#pragma clang diagnostic pop

#import "YINA-Swift.h"

#define LOG_DEBUG(msg, ...) [FFmpegLogger debug:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];
#define LOG_ERROR(msg, ...) [FFmpegLogger error:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];
#define LOG_WARN(msg, ...) [FFmpegLogger warn:([NSString stringWithFormat:(msg), ##__VA_ARGS__])];

#define THUMB_COUNT_DEFAULT 100

#define CHECK_NOTNULL(ptr,msg) if (ptr == NULL) {\
LOG_ERROR(@"Error when getting thumbnails: %@", msg);\
return -1;\
}

#define CHECK_SUCCESS(ret,msg) if (ret < 0) {\
LOG_ERROR(@"Error when getting thumbnails: %@ (%d)", msg, ret);\
return -1;\
}

#define CHECK(ret,msg) if (!(ret)) {\
LOG_ERROR(@"Error when getting thumbnails: %@", msg);\
return -1;\
}

@implementation FFThumbnail

@end


@interface FFmpegController () {
  NSMutableArray<FFThumbnail *> *_thumbnails;
  NSMutableArray<FFThumbnail *> *_thumbnailPartialResult;
  NSMutableSet *_addedTimestamps;
  NSOperationQueue *_queue;
  double _timestamp;
}

- (int)getPeeksForFile:(NSString *)file thumbnailsWidth:(int)thumbnailsWidth requestedTime:(double)requestedTime operation:(NSOperation *)operation;
- (void)saveThumbnail:(AVFrame *)pFrame width:(int)width height:(int)height index:(int)index realTime:(int)second forFile:(NSString *)file;

@end


@implementation FFmpegController

- (instancetype)init
{
  self = [super init];
  if (self) {
    self.thumbnailCount = THUMB_COUNT_DEFAULT;
    _thumbnails = [[NSMutableArray alloc] init];
    _thumbnailPartialResult = [[NSMutableArray alloc] init];
    _addedTimestamps = [[NSMutableSet alloc] init];
    _queue = [[NSOperationQueue alloc] init];
    _queue.maxConcurrentOperationCount = 1;
  }
  return self;
}

// MARK: - Generating Thumbnails

- (void)generateThumbnailForFile:(NSString *)file
                      thumbWidth:(int)thumbWidth
{
  [self generateThumbnailForFile:file atTime:NAN thumbWidth:thumbWidth];
}

- (void)generateThumbnailForFile:(NSString *)file
                           atTime:(double)time
                       thumbWidth:(int)thumbWidth
{
  [_queue cancelAllOperations];
  NSBlockOperation *op = [[NSBlockOperation alloc] init];
  __weak NSBlockOperation *weakOp = op;
  [op addExecutionBlock:^(){
    if ([weakOp isCancelled]) {
      return;
    }
    self->_timestamp = CACurrentMediaTime();
    int success = [self getPeeksForFile:file thumbnailsWidth:thumbWidth requestedTime:time operation:weakOp];
    if (self.delegate) {
      [self.delegate didGenerateThumbnails:[NSArray arrayWithArray:self->_thumbnails]
                                   forFile: file
                                 succeeded:(success < 0 ? NO : YES)];
    }
  }];
  [_queue addOperation:op];
}

- (void)cancelThumbnailGeneration
{
  [_queue cancelAllOperations];
}

- (int)getPeeksForFile:(NSString *)file
       thumbnailsWidth:(int)thumbnailsWidth
         requestedTime:(double)requestedTime
             operation:(NSOperation *)operation
{
  int i, ret;

  char *cFilename = strdup(file.fileSystemRepresentation);
  [_thumbnails removeAllObjects];
  [_thumbnailPartialResult removeAllObjects];
  [_addedTimestamps removeAllObjects];

  // Register all formats and codecs. mpv should have already called it.
  // av_register_all();

  // Open video file
  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  CHECK_SUCCESS(ret, @"Cannot open video")

  // Find stream information
  ret = avformat_find_stream_info(pFormatCtx, NULL);
  CHECK_SUCCESS(ret, @"Cannot get stream info")

  // Find the first video stream
  int videoStream = -1;
  for (i = 0; i < pFormatCtx->nb_streams; i++)
    if (pFormatCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      videoStream = i;
      break;
    }
  CHECK_SUCCESS(videoStream, @"No video stream")

  // Get the codec context for the video stream
  AVStream *pVideoStream = pFormatCtx->streams[videoStream];

  AVRational videoAvgFrameRate = pVideoStream->avg_frame_rate;

  // Check whether the denominator (AVRational.den) is zero to prevent division-by-zero
  if (videoAvgFrameRate.den == 0 || av_q2d(videoAvgFrameRate) == 0) {
    LOG_DEBUG(@"Avg frame rate = 0, ignore");
    return -1;
  }

  // Find the decoder for the video stream
  const AVCodec *pCodec = avcodec_find_decoder(pVideoStream->codecpar->codec_id);
  CHECK_NOTNULL(pCodec, @"Unsupported codec")

  // Open codec
  AVCodecContext *pCodecCtx = avcodec_alloc_context3(pCodec);
  AVDictionary *optionsDict = NULL;

  avcodec_parameters_to_context(pCodecCtx, pVideoStream->codecpar);
  pCodecCtx->time_base = pVideoStream->time_base;

  if (pCodecCtx->pix_fmt < 0 || pCodecCtx->pix_fmt >= AV_PIX_FMT_NB) {
    avcodec_free_context(&pCodecCtx);
    avformat_close_input(&pFormatCtx);
    LOG_ERROR(@"Error when getting thumbnails: Pixel format is null");
    return -1;
  }

  ret = avcodec_open2(pCodecCtx, pCodec, &optionsDict);
  CHECK_SUCCESS(ret, @"Cannot open codec")

  // Allocate video frame
  AVFrame *pFrame = av_frame_alloc();
  CHECK_NOTNULL(pFrame, @"Cannot alloc video frame")

  // Allocate the output frame
  // We need to convert the video frame to RGBA to satisfy CGImage's data format
  int thumbWidth = thumbnailsWidth;
  int thumbHeight = (float)thumbWidth / ((float)pCodecCtx->width / pCodecCtx->height);

  AVFrame *pFrameRGB = av_frame_alloc();
  CHECK_NOTNULL(pFrameRGB, @"Cannot alloc RGBA frame")

  pFrameRGB->width = thumbWidth;
  pFrameRGB->height = thumbHeight;
  BOOL isHDR = pCodecCtx->color_trc == AVCOL_TRC_SMPTE2084 || pCodecCtx->color_trc == AVCOL_TRC_ARIB_STD_B67;
  pFrameRGB->format = isHDR ? AV_PIX_FMT_RGBA64LE : AV_PIX_FMT_RGBA;
  pFrameRGB->color_trc = pCodecCtx->color_trc;
  pFrameRGB->color_primaries = pCodecCtx->color_primaries;

  // Determine required buffer size and allocate buffer
  int size = av_image_get_buffer_size(pFrameRGB->format, thumbWidth, thumbHeight, 1);
  uint8_t *pFrameRGBBuffer = (uint8_t *)av_malloc(size);

  // Assign appropriate parts of buffer to image planes in pFrameRGB
  ret = av_image_fill_arrays(pFrameRGB->data,
                             pFrameRGB->linesize,
                             pFrameRGBBuffer,
                             pFrameRGB->format,
                             pFrameRGB->width,
                             pFrameRGB->height, 1);
  CHECK_SUCCESS(ret, @"Cannot fill data for RGBA frame")

  // Create a sws context for converting color space and resizing
  CHECK(pCodecCtx->pix_fmt != AV_PIX_FMT_NONE, @"Pixel format is none")
  struct SwsContext *sws_ctx = sws_getContext(pCodecCtx->width, pCodecCtx->height, pCodecCtx->pix_fmt,
                                              pFrameRGB->width, pFrameRGB->height, pFrameRGB->format,
                                              SWS_BILINEAR,
                                              NULL, NULL, NULL);

  // Get duration and interval. A welcome card asks for a single saved-position
  // frame; timeline peeks retain their established evenly-spaced behaviour.
  int64_t duration = av_rescale_q(pFormatCtx->duration, AV_TIME_BASE_Q, pVideoStream->time_base);
  double interval = duration / (double)self.thumbnailCount;
  double timebaseDouble = av_q2d(pVideoStream->time_base);
  AVPacket packet;
  BOOL hasRequestedTime = isfinite(requestedTime);
  int lastThumbnailIndex = hasRequestedTime ? 0 : self.thumbnailCount;

  // For each preview point
  for (i = 0; i <= lastThumbnailIndex; i++) {
    int64_t seek_pos = hasRequestedTime
      ? av_rescale_q((int64_t)MAX(0, requestedTime * AV_TIME_BASE),
                     AV_TIME_BASE_Q, pVideoStream->time_base) + pVideoStream->start_time
      : interval * i + pVideoStream->start_time;

    avcodec_flush_buffers(pCodecCtx);

    // Seek to time point
    // avformat_seek_file(pFormatCtx, videoStream, seek_pos-interval, seek_pos, seek_pos+interval, 0);
    ret = av_seek_frame(pFormatCtx, videoStream, seek_pos, AVSEEK_FLAG_BACKWARD);
    CHECK_SUCCESS(ret, @"Cannot seek")

    avcodec_flush_buffers(pCodecCtx);

    // Read and decode frame
    while(!operation.isCancelled && av_read_frame(pFormatCtx, &packet) >= 0) {
      @try {
        // Make sure it's video stream
        if (packet.stream_index == videoStream) {

          // Decode video frame
          if (avcodec_send_packet(pCodecCtx, &packet) < 0)
            break;

          ret = avcodec_receive_frame(pCodecCtx, pFrame);
          if (ret < 0) {  // something happened
            if (ret == AVERROR(EAGAIN))  // input not ready, retry
              continue;
            else
              break;
          }

          // Check if duplicated
          NSNumber *currentTimeStamp = @(pFrame->best_effort_timestamp);
          if ([_addedTimestamps containsObject:currentTimeStamp]) {
            double currentTime = CACurrentMediaTime();
            if (currentTime - _timestamp > 1) {
              if (self.delegate) {
                [self.delegate didUpdateThumbnails:NULL forFile: file withProgress: i];
                _timestamp = currentTime;
              }
            }
            break;
          } else {
            [_addedTimestamps addObject:currentTimeStamp];
          }

          // Convert the frame to RGBA
          enum AVColorTransferCharacteristic transfer = pFrame->color_trc != AVCOL_TRC_UNSPECIFIED ? pFrame->color_trc : pCodecCtx->color_trc;
          BOOL frameIsHDR = transfer == AVCOL_TRC_SMPTE2084 || transfer == AVCOL_TRC_ARIB_STD_B67;
          enum AVPixelFormat outputFormat = frameIsHDR ? AV_PIX_FMT_RGBA64LE : AV_PIX_FMT_RGBA;
          if (pFrameRGB->format != outputFormat) {
            av_free(pFrameRGBBuffer);
            pFrameRGB->format = outputFormat;
            size = av_image_get_buffer_size(outputFormat, thumbWidth, thumbHeight, 1);
            pFrameRGBBuffer = av_malloc(size);
            CHECK_NOTNULL(pFrameRGBBuffer, @"Cannot alloc HDR frame buffer")
            ret = av_image_fill_arrays(pFrameRGB->data, pFrameRGB->linesize, pFrameRGBBuffer,
                                       outputFormat, thumbWidth, thumbHeight, 1);
            CHECK_SUCCESS(ret, @"Cannot fill HDR frame buffer")
          }
          pFrameRGB->color_trc = transfer;
          pFrameRGB->color_primaries = pFrame->color_primaries != AVCOL_PRI_UNSPECIFIED ? pFrame->color_primaries : pCodecCtx->color_primaries;
          sws_ctx = sws_getCachedContext(sws_ctx, pFrame->width, pFrame->height, pFrame->format,
                                        thumbWidth, thumbHeight, outputFormat, SWS_BILINEAR, NULL, NULL, NULL);
          CHECK_NOTNULL(sws_ctx, @"Cannot create thumbnail scaler")
          // swscale preserves the transfer function; select the source YUV matrix and
          // range explicitly so BT.2020 video does not use the default BT.601 matrix.
          enum AVColorSpace matrix = pFrame->colorspace != AVCOL_SPC_UNSPECIFIED ? pFrame->colorspace : pCodecCtx->colorspace;
          int coefficients = matrix == AVCOL_SPC_BT2020_NCL || matrix == AVCOL_SPC_BT2020_CL ? SWS_CS_BT2020 :
                             matrix == AVCOL_SPC_BT709 ? SWS_CS_ITU709 :
                             matrix == AVCOL_SPC_SMPTE240M ? SWS_CS_SMPTE240M : SWS_CS_DEFAULT;
          enum AVColorRange range = pFrame->color_range != AVCOL_RANGE_UNSPECIFIED ? pFrame->color_range : pCodecCtx->color_range;
          const int *table = sws_getCoefficients(coefficients);
          sws_setColorspaceDetails(sws_ctx, table, range == AVCOL_RANGE_JPEG, table, 1, 0, 1 << 16, 1 << 16);
          ret = sws_scale(sws_ctx,
                          (const uint8_t* const *)pFrame->data,
                          pFrame->linesize,
                          0,
                          pFrame->height,
                          pFrameRGB->data,
                          pFrameRGB->linesize);
          CHECK_SUCCESS(ret, @"Cannot convert frame")

          // Save the frame to disk
          [self saveThumbnail:pFrameRGB
                        width:pFrameRGB->width
                       height:pFrameRGB->height
                        index:i
                     realTime:(pFrame->best_effort_timestamp * timebaseDouble)
                      forFile:file];
          break;
        }
      } @finally {
        // Free the packet
        av_packet_unref(&packet);
      }
    }
  }
  // Free the scaler
  sws_freeContext(sws_ctx);

  // Free the RGB image
  av_free(pFrameRGBBuffer);
  av_frame_free(&pFrameRGB);
  // Free the YUV frame
  av_frame_free(&pFrame);

  // Free the codec
  avcodec_free_context(&pCodecCtx);
  // Close the video file
  avformat_close_input(&pFormatCtx);

  // LOG_DEBUG(@"Thumbnails generated.");
  return 0;
}



// MARK: - HDR preview tone mapping

/// Convert a PQ (SMPTE ST 2084) code value to linear light, normalised so that
/// 1.0 corresponds to 10000 cd/m2. Implements the inverse EOTF from the standard.
static inline float YINAPQToLinear(float V) {
  const float m1 = 0.1593017578125f;
  const float m2 = 78.84375f;
  const float c1 = 0.8359375f;
  const float c2 = 18.8515625f;
  const float c3 = 18.6875f;
  if (V <= 0.0f) { return 0.0f; }
  float Vp = powf(V, 1.0f / m2);
  if (Vp <= c1) { return 0.0f; }
  float den = c2 - c3 * Vp;
  if (den <= 0.0f) { return 0.0f; }
  return powf((Vp - c1) / den, 1.0f / m1);
}

/// Convert an HLG (ARIB STD-B67) signal to scene-linear light, normalised so
/// that 1.0 corresponds to the nominal 1000 cd/m2 peak.
static inline float YINAHLGToLinear(float E) {
  const float a = 0.17883277f;
  const float b = 0.28466892f;
  const float c = 0.55991073f;
  if (E <= 0.0f) { return 0.0f; }
  if (E >= 1.0f) { return 1.0f; }
  // Inverse of the HLG OETF. The 1/12 break used by the forward curve does not
  // apply here: the decode branch is at signal 0.5 (scene 1/12).
  if (E <= 0.5f) { return (E * E) / 3.0f; }
  return (expf((E - c) / a) + b) / 12.0f;
}

/// Tone map one HDR component to an 8-bit sRGB code.
///
/// The preview is meant to look like the picture on screen, not to carry HDR
/// precision. Displaying PQ-coded values directly lifts the midtones and looks
/// washed out, so decode the transfer function, scale against the BT.2408
/// reference white, and roll highlights off gently before applying the sRGB
/// transfer function.
///
/// - Parameter V:     the 16-bit PQ or HLG code value.
/// - Parameter isPQ:  YES for PQ (SMPTE ST 2084), NO for HLG (ARIB STD-B67).
static inline uint8_t YINAToneMapHDRToSRGB(uint16_t V, bool isPQ) {
  const float kReferenceWhiteNits = 203.0f;  // ITU-R BT.2408 HDR reference white
  const float kPeakNits = isPQ ? 10000.0f : 1000.0f;
  float code = (float)V / 65535.0f;
  float linear = isPQ ? YINAPQToLinear(code) : YINAHLGToLinear(code);
  float nits = linear * kPeakNits;

  // Linear up to reference white so midtones keep their contrast, then a gentle
  // logarithmic shoulder so highlights separate instead of clipping as one block.
  float L = nits / kReferenceWhiteNits;
  float y = L <= 1.0f ? L : 1.0f + log1pf(L) * 0.15f;
  if (y < 0.0f) { y = 0.0f; }
  if (y > 1.0f) { y = 1.0f; }

  // Apply the sRGB transfer function; the output is a non-linear 8-bit code.
  float srgb = y <= 0.0031308f ? y * 12.92f : 1.055f * powf(y, 1.0f / 2.4f) - 0.055f;
  int v = (int)(srgb * 255.0f + 0.5f);
  if (v < 0) { v = 0; }
  if (v > 255) { v = 255; }
  return (uint8_t)v;
}

- (void)saveThumbnail:(AVFrame *)pFrame width
                     :(int)width height
                     :(int)height index
                     :(int)index realTime
                     :(int)second forFile
                     :(NSString *)file
{
  // Create CGImage
  //
  // A preview is shown on screen next to the video, so it must read like the
  // video. Carrying the HDR transfer function through to an 8-bit sRGB image
  // lifts the midtones and looks washed out, so HDR frames are tone mapped into
  // sRGB here instead. That also lets every preview use the same 8-bit format,
  // which keeps the thumbnail cache an order of magnitude smaller.
  BOOL isHDR = pFrame->format == AV_PIX_FMT_RGBA64LE;
  CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGImageRef cgImage = NULL;

  if (isHDR) {
    // Tone map into an 8-bit sRGB buffer. This keeps the preview consistent with
    // what is on screen and avoids storing 16-bit samples for every frame.
    BOOL isPQ = pFrame->color_trc == AVCOL_TRC_SMPTE2084;
    const uint16_t *src = (const uint16_t *)pFrame->data[0];
    const int srcStride = pFrame->linesize[0] / (int)sizeof(uint16_t);
    const size_t dstStride = (size_t)width * 4;
    uint8_t *dst = (uint8_t *)malloc(dstStride * (size_t)height);
    if (!dst) {
      CGColorSpaceRelease(rgb);
      LOG_ERROR(@"Cannot alloc tone mapped thumbnail buffer");
      return;
    }
    for (int y = 0; y < height; y++) {
      const uint16_t *srcRow = src + (size_t)y * srcStride;
      uint8_t *dstRow = dst + (size_t)y * dstStride;
      for (int x = 0; x < width; x++) {
        // RGBA64LE stores each component as a little-endian 16-bit value.
        const uint16_t *px = srcRow + (size_t)x * 4;
        dstRow[x * 4 + 0] = YINAToneMapHDRToSRGB(px[0], isPQ);
        dstRow[x * 4 + 1] = YINAToneMapHDRToSRGB(px[1], isPQ);
        dstRow[x * 4 + 2] = YINAToneMapHDRToSRGB(px[2], isPQ);
        dstRow[x * 4 + 3] = (uint8_t)(px[3] > 65535 ? 255 : (px[3] >> 8));
      }
    }
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, dst, dstStride * (size_t)height, NULL);
    if (provider) {
      cgImage = CGImageCreate(width, height, 8, 32, (size_t)dstStride, rgb,
                              kCGImageAlphaLast, provider, NULL, true, kCGRenderingIntentDefault);
      CGDataProviderRelease(provider);
    }
    free(dst);
    if (!cgImage) {
      CGColorSpaceRelease(rgb);
      LOG_ERROR(@"Cannot create tone mapped thumbnail image");
      return;
    }
  } else {
    // Copy the pixels: the decoder reuses its buffer for subsequent thumbnails.
    CFDataRef pixels = CFDataCreate(NULL, pFrame->data[0], pFrame->linesize[0] * height);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CGImageRef created = CGImageCreate(width, height, 8, 32,
                                      pFrame->linesize[0], rgb, kCGImageAlphaLast,
                                      provider, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CFRelease(pixels);
    if (!created) {
      CGColorSpaceRelease(rgb);
      LOG_ERROR(@"Cannot create thumbnail image");
      return;
    }
    cgImage = created;
  }

  CGColorSpaceRelease(rgb);

  // Create NSImage
  NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size: NSZeroSize];

  // Free resources
  CGImageRelease(cgImage);

  // Add to list
  FFThumbnail *tb = [[FFThumbnail alloc] init];
  tb.image = image;
  tb.realTime = second;
  [_thumbnails addObject:tb];
  [_thumbnailPartialResult addObject:tb];
  // Post update notification
  double currentTime = CACurrentMediaTime();
  if (_thumbnails.count == 1 || currentTime - _timestamp >= 0.2) {  // Send the first frame immediately.
    if (_thumbnails.count == 1 || _thumbnailPartialResult.count >= 10 || (currentTime - _timestamp >= 1 && _thumbnailPartialResult.count > 0)) {
      if (self.delegate) {
        [self.delegate didUpdateThumbnails:[NSArray arrayWithArray:_thumbnailPartialResult]
                                   forFile: file
                              withProgress: index];
      }
      [_thumbnailPartialResult removeAllObjects];
      _timestamp = currentTime;
    }
  }
}

// MARK: - Probing Video

+ (NSDictionary *)probeVideoInfoForFile:(nonnull NSString *)file
{
  int ret;
  int64_t duration;

  char *cFilename = strdup(file.fileSystemRepresentation);

  AVFormatContext *pFormatCtx = NULL;
  ret = avformat_open_input(&pFormatCtx, cFilename, NULL, NULL);
  free(cFilename);
  if (ret < 0) {
    LOG_ERROR(@"Error when opening file %@ to obtain info: %s (%d)", file, av_err2str(ret), ret);
    return NULL;
  }

  duration = pFormatCtx->duration;
  if (duration <= 0) {
    ret = avformat_find_stream_info(pFormatCtx, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Error when probing %@ to obtain info: %s (%d)", file, av_err2str(ret), ret);
      duration = -1;
    } else
      duration = pFormatCtx->duration;
  }

  // In addition to the duration YINA is interested metadata tags, especially the title tag. In many
  // formats metadata is attached to the container itself. However in Ogg files metadata is attached
  // to the stream. If the title tag is not found in the metadata from the container then search for
  // an audio stream. If an audio stream with metadata containing a title tag is found then use the
  // metadata from the stream instead of from the container. This addresses issue #5314.
  AVDictionary *metadata = pFormatCtx->metadata;
  if (av_dict_get(metadata, "title", NULL, 0) == NULL) {
    ret = av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (ret < 0) {
      // Don't report an error when there isn't an audio stream.
      if (ret != AVERROR_STREAM_NOT_FOUND) {
        LOG_ERROR(@"Error when probing %@ to obtain best stream: %s (%d)", file, av_err2str(ret), ret);
      }
    } else if (av_dict_get(pFormatCtx->streams[ret]->metadata, "title", NULL, 0) != NULL) {
      metadata = pFormatCtx->streams[ret]->metadata;
    }
  }

  NSMutableDictionary *info = [[NSMutableDictionary alloc] init];
  info[@"@iina_duration"] = duration == -1 ? [NSNumber numberWithInt:-1] : [NSNumber numberWithDouble:(double)duration / AV_TIME_BASE];
  AVDictionaryEntry *tag = NULL;
  while ((tag = av_dict_get(metadata, "", tag, AV_DICT_IGNORE_SUFFIX))) {
    // FFmpeg may return strings that are not valid. See issue #5602.
    const NSString *key = [NSString stringWithCString:tag->key encoding:NSUTF8StringEncoding];
    if (!key) {
      LOG_WARN(@"Cannot construct a string for a metadata tag key");
      continue;
    }
    const NSString *value = [NSString stringWithCString:tag->value encoding:NSUTF8StringEncoding];
    if (!value) {
      LOG_WARN(@"Cannot construct a string for the value of the metadata tag key: %@", key);
      continue;
    }
    info[key] = value;
  }

  avformat_close_input(&pFormatCtx);
  avformat_free_context(pFormatCtx);

  return info;
}

// MARK: - Decoding Image

+ (NSImage *)createNSImageWithContentsOfURL:(nonnull NSURL *)url
{
  // Variables holding objects that will need to be freed.
  AVFormatContext *pFormatCtx = NULL;
  AVCodecContext *pCodecCtx = NULL;
  AVPacket *packet = NULL;
  AVFrame *pFrame = NULL;
  AVFrame *pFrameRGB = NULL;
  uint8_t *pFrameRGBBuffer = NULL;
  struct SwsContext *swsContext = NULL;
  CGColorSpaceRef cgColorSpace = NULL;
  CGContextRef cgContext = NULL;
  CGImageRef cgImage = NULL;

  @try {
#if DEBUG
    LOG_DEBUG(@"Creating image with contents of file: %s", url.fileSystemRepresentation)
#endif

    int ret = avformat_open_input(&pFormatCtx, url.fileSystemRepresentation, NULL, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Error when opening file %@ to construct NSImage: %s (%d)", url, av_err2str(ret), ret);
      return NULL;
    }

    ret = avformat_find_stream_info(pFormatCtx, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Cannot get stream info: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

    // Expecting image files to have one video stream.
    if (pFormatCtx->nb_streams != 1) {
      LOG_ERROR(@"Expected one stream found: %d", pFormatCtx->nb_streams);
      return NULL;
    }
    const AVStream *pVideoStream = pFormatCtx->streams[0];
    const enum AVMediaType codecType = pVideoStream->codecpar->codec_type;
    if (codecType != AVMEDIA_TYPE_VIDEO) {
      LOG_ERROR(@"Unexpected stream type: %s (%d)", av_get_media_type_string(codecType), codecType);
      return NULL;
    }
    // Expecting the number of frames to be unknown (0) or 1.
    if (pVideoStream->nb_frames > 1) {
      LOG_ERROR(@"Expected one frame found: %lld", pVideoStream->nb_frames);
      return NULL;
    }

    const AVCodec *pCodec = avcodec_find_decoder(pVideoStream->codecpar->codec_id);
    if (!pCodec) {
      LOG_ERROR(@"Cannot get decoder codec: %d", pVideoStream->codecpar->codec_id);
      return NULL;
    }

    // This method is only intended to be used for JPEG XL or WebP encoded images. As only these
    // formats have been tested, refuse to process other formats.
    if (pCodec->id != AV_CODEC_ID_JPEGXL && pCodec->id != AV_CODEC_ID_WEBP) {
      LOG_ERROR(@"Unexpected encoding: %s (%d)", pCodec->name, pCodec->id);
      return NULL;
    }

    pCodecCtx = avcodec_alloc_context3(pCodec);
    if (!pCodecCtx) {
      LOG_ERROR(@"Cannot alloc codec context: %s (%d)", pCodec->name, pCodec->id);
      return NULL;
    }
    avcodec_parameters_to_context(pCodecCtx, pVideoStream->codecpar);
    if (pCodecCtx->pix_fmt < 0 || pCodecCtx->pix_fmt >= AV_PIX_FMT_NB) {
      LOG_ERROR(@"Invalid pixel format: %d", pCodecCtx->pix_fmt);
      return NULL;
    }

    // Permit use of multiple threads for decoding. By default thread count is set to one which
    // disables use of multiple threads. Setting it to zero allows the codec to use multiple
    // threads. This is only done if the codec has the capability of using multiple threads for
    // decoding an individual frame as testing showed the WebP codec, which does not have this
    // capability, reacted badly to being given permission to use multiple threads. When this
    // property was set to anything other than one WebP decoding failed with "Resource temporarily
    // unavailable". The JPEG XL codec has this capability and will take advantage of multiple
    // threads. Testing on a MacBook Pro with the M1 Max chip showed a 40% reduction in the time to
    // decode a JPEG XL screenshot of a 4K video when using multiple threads. Normally speed of
    // decoding is not an issue, however mpv provides screenshot options that control the encoding
    // compression and quality. Changing these settings can result in the creation of screenshots
    // that take multiple seconds to decode. The thread count must be set before opening the codec.
    if (pCodec->capabilities & AV_CODEC_CAP_OTHER_THREADS) {
      pCodecCtx->thread_count = 0;
    }

    ret = avcodec_open2(pCodecCtx, pCodec, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Cannot open codec: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

    packet = av_packet_alloc();
    ret = av_read_frame(pFormatCtx, packet);
    if (ret < 0) {
      LOG_ERROR(@"Cannot read packet: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }
    if (packet->stream_index != 0) {
      LOG_ERROR(@"Unexpected video stream: %d", packet->stream_index);
      return NULL;
    }

    pFrame = av_frame_alloc();
    if (!pFrame) {
      LOG_ERROR(@"Cannot alloc frame");
      return NULL;
    }

    ret = avcodec_send_packet(pCodecCtx, packet);
    if (ret < 0) {
      LOG_ERROR(@"Cannot send packet: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }
    ret = avcodec_receive_frame(pCodecCtx, pFrame);
    if (ret < 0) {
      LOG_ERROR(@"Cannot receive frame: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

#if DEBUG
    [FFmpegController logFrame:pCodec:pFrame];
#endif

    // CGImage requires the image frame to be converted to RGBA.
    pFrameRGB = av_frame_alloc();
    if (!pFrameRGB) {
      LOG_ERROR(@"Cannot alloc RGBA frame");
      return NULL;
    }
    pFrameRGB->width = pFrame->width;
    pFrameRGB->height = pFrame->height;

    // Determine the appropriate RGBA pixel format to convert to.
    CGBitmapInfo bitmapInfo;
    switch (pFrame->format) {
      default:
        // If this message is logged then the situation needs to be investigated to determine the
        // correct conversion. Fall through and treat this as a SDR image.
        LOG_WARN(@"Unexpected pixel format: %s (%d)", av_get_pix_fmt_name(pFrame->format),
             pFrame->format);
      case AV_PIX_FMT_ARGB: // WebP with screenshot-webp-lossless mpv option enabled.
      case AV_PIX_FMT_RGB24: // JPEG XL SDR video.
      case AV_PIX_FMT_RGBA64LE: // JPEG XL SDR video.
      case AV_PIX_FMT_YUV420P: // WebP default.
        pFrameRGB->format = AV_PIX_FMT_RGBA;
        bitmapInfo = (CGBitmapInfo)kCGImageAlphaPremultipliedLast;
        break;
      case AV_PIX_FMT_RGB48LE: // JPEG XL HDR video.
        // Workaround missing FFmpeg 6.0 scalar capabilities. As per Apple EDR requires using 16 bit
        // floating point components in the image bit map. Therefore we want the scalar to convert
        // the frame to the AV_PIX_FMT_RGBAF16LE pixel format. However when that was specified the
        // call to sws_getContext returned NULL. The scalar printed the message "rgbaf16le is not
        // supported as output pixel format" to the console. As a workaround we convert to
        // AV_PIX_FMT_RGBA64LE and then convert the components to floating point.
        pFrameRGB->format = AV_PIX_FMT_RGBA64LE;
        bitmapInfo = (CGBitmapInfo)kCGImageByteOrder16Little |
                     (CGBitmapInfo)kCGImageAlphaPremultipliedLast |
                     kCGBitmapFloatComponents;
    }

    // Determine required buffer size and allocate the buffer.
    const int size = av_image_get_buffer_size(pFrameRGB->format, pFrame->width, pFrame->height, 1);
    pFrameRGBBuffer = (uint8_t *)av_malloc(size);
    if (!pFrameRGBBuffer) {
      LOG_ERROR(@"Cannot alloc RGBA buffer");
      return NULL;
    }

    // Assign appropriate parts of buffer to image planes in pFrameRGB.
    ret = av_image_fill_arrays(pFrameRGB->data, pFrameRGB->linesize, pFrameRGBBuffer,
        pFrameRGB->format, pFrameRGB->width, pFrameRGB->height, 1);
    if (ret < 0) {
      LOG_ERROR(@"Cannot fill data for RGBA frame: %s (%d)", av_err2str(ret), ret);
      return NULL;
    }

    // Convert the image frame to RGBA using the FFmpeg scaler.
    swsContext = sws_getContext(pFrame->width, pFrame->height, pFrame->format,
        pFrameRGB->width, pFrameRGB->height, pFrameRGB->format, SWS_BILINEAR, NULL, NULL, NULL);
    if (!swsContext) {
      LOG_ERROR(@"Cannot alloc sws context");
      return NULL;
    }
    sws_scale(swsContext, (const uint8_t* const *)pFrame->data, pFrame->linesize, 0, pFrame->height,
        pFrameRGB->data, pFrameRGB->linesize);

    // Obtain information about the pixel format that is needed to create the bitmap image.
    const AVPixFmtDescriptor *pixFmtDesc = av_pix_fmt_desc_get(pFrameRGB->format);
    if (!pixFmtDesc){
      LOG_ERROR(@"Cannot get descriptor for pixel format: %s (%d)",
            av_get_pix_fmt_name(pFrameRGB->format), pFrameRGB->format);
      return NULL;
    }
    const int bitsPerPixel = av_get_bits_per_pixel(pixFmtDesc);
    const int bitsPerComponent = bitsPerPixel / pixFmtDesc->nb_components;
    const int bytesPerPixel = bitsPerPixel / 8;

    if (pFrameRGB->format == AV_PIX_FMT_RGBA64LE) {
      const int bytesPerComponent = bitsPerComponent / 8;

      // Each row of pixels in memory may contain extra padding for performance reasons. The
      // linesize gives the actual number of bytes each row consumes in the frame buffer.
      const int strideInBytes = pFrameRGB->linesize[0];

      // Apply the second part of the workaround for the FFmpeg scalar not supporting conversion to
      // the pixel format AV_PIX_FMT_RGBAF16LE. Convert the pixel components to short floating point
      // values. This is an in-place conversion, which is supported by vImageConvert_16Uto16F, so
      // only one buffer is used.
      const vImage_Buffer buffer = {.width = pFrameRGB->width * bytesPerPixel / bytesPerComponent,
        .height = pFrameRGB->height, .rowBytes = strideInBytes, .data = pFrameRGB->data[0]};
      const vImage_Error error = vImageConvert_16Uto16F(&buffer, &buffer, kvImageNoFlags);
      if (error != kvImageNoError) {
        LOG_ERROR(@"Method vImageConvert_16Uto16F failed: %ld", error);
        return NULL;
      }
    }

    // Determine the color space to use for the image.
    switch (pFrame->color_primaries) {
      default:
        // If this message is logged then the situation needs to be investigated to determine the
        // correct color space. Fall through and treat this as a SDR image.
        LOG_WARN(@"Unexpected color primaries: %s (%d)",
             av_color_primaries_name(pFrame->color_primaries), pFrame->color_primaries);
      case AVCOL_PRI_UNSPECIFIED:
      case AVCOL_PRI_BT709:
        cgColorSpace = CGColorSpaceCreateDeviceRGB();
        break;
      case AVCOL_PRI_BT2020:
        switch (pFrame->color_trc) {
          default:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
            break;
          case AVCOL_TRC_ARIB_STD_B67:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_HLG);
            break;
          case AVCOL_TRC_SMPTE2084:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
        }
        break;
      case AVCOL_PRI_SMPTE432:
        switch (pFrame->color_trc) {
          default:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
            break;
          case AVCOL_TRC_ARIB_STD_B67:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3_HLG);
            break;
          case AVCOL_TRC_SMPTE2084:
            cgColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3_PQ);
        }
    }
    if (!cgColorSpace) {
      LOG_ERROR(@"Cannot create color space");
      return NULL;
    }

#if DEBUG
    LOG_DEBUG(@"Selected %s color space for bitmap image",
        CFStringGetCStringPtr(CGColorSpaceCopyName(cgColorSpace), CFStringGetSystemEncoding()));
    LOG_DEBUG(@"Creating bitmap image with %d bits per component and %d bytes per pixel",
        bitsPerComponent, bytesPerPixel);
#endif

    cgContext = CGBitmapContextCreate(pFrameRGB->data[0], pFrameRGB->width, pFrameRGB->height,
        bitsPerComponent, pFrameRGB->width * bytesPerPixel, cgColorSpace, bitmapInfo);
    if (!cgContext) {
      LOG_ERROR(@"Cannot create bitmap context");
      return NULL;
    }
    cgImage = CGBitmapContextCreateImage(cgContext);
    if (!cgImage) {
      LOG_ERROR(@"Cannot create bitmap image");
      return NULL;
    }

    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size: NSZeroSize];
    if (!image) {
      LOG_ERROR(@"Cannot create image");
    }
    return image;
  }
  @finally {
    // All of these methods accept null, no need to check if the object was allocated.
    CGImageRelease(cgImage);
    CGContextRelease(cgContext);
    CGColorSpaceRelease(cgColorSpace);
    sws_freeContext(swsContext);
    av_freep(&pFrameRGBBuffer);
    av_frame_free(&pFrameRGB);
    av_frame_free(&pFrame);
    av_packet_free(&packet);
    avcodec_free_context(&pCodecCtx);
    avformat_close_input(&pFormatCtx);
  }
}

// MARK: - Media Artwork

+ (NSImage *)readArtworkFromURL:(nonnull NSURL *)url
{
  AVFormatContext *pFormatCtx = NULL;

  @try {
    int ret = avformat_open_input(&pFormatCtx, url.fileSystemRepresentation, NULL, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Failed to open file %@ when searching for artwork: %s (%d)", url, av_err2str(ret), ret);
      return NULL;
    }

    ret = avformat_find_stream_info(pFormatCtx, NULL);
    if (ret < 0) {
      LOG_ERROR(@"Failed to obtain stream info from file %@ when searching for artwork: %s (%d)",
                url, av_err2str(ret), ret);
      return NULL;
    }

    // Search the streams for one that contains front cover artwork.
    int index = 0;
    AVPacket* packet = NULL;
    for (int i = 0; i < pFormatCtx->nb_streams; i++) {
      AVStream* stream = pFormatCtx->streams[i];

      // For this stream to be cover artwork it must be an attached picture (APIC).
      if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) == 0) { continue; }

      // And it must not be a stream of thumbnail images.
      if ((stream->disposition & AV_DISPOSITION_TIMED_THUMBNAILS) != 0) { continue; }

      // If a stream passes these two checks mpv identifies it as album art. To match up with mpv
      // this is all YINA checks as well. ID3v2 defines picture types, but I did not find any code
      // in mpv checking to confirm the image is marked as front cover art. The list of picture
      // types can be found here: https://id3.org/id3v2.3.0#Attached_picture

      // Found front cover artwork.
      index = i;
      packet = &stream->attached_pic;
      break;
    }

    if (!packet) {
      return NULL;
    }

    // Form an image from the stream's data.
    LOG_DEBUG(@"Creating an image from stream %d using %d bytes", index, packet->size);
    NSData *data = [[NSData alloc] initWithBytes:packet->data length:packet->size];
    NSImage *image = [[NSImage alloc] initWithData:data];
    if (!image) {
      LOG_ERROR(@"Cannot create image from artwork for file: %@", url);
    }
    return image;
  }
  @finally {
    avformat_close_input(&pFormatCtx);
  }
}

// MARK: - Logging

#if DEBUG
/// Log details about the given decoded frame.
/// - Parameters:
///   - pCodec: The codec that decoded the frame.
///   - pFrame: The decoded frame to log.
+ (void)logFrame:(const AVCodec *)pCodec
                :(const AVFrame *)pFrame
{
  LOG_DEBUG(@"Decoded %s frame", pCodec->long_name);
  LOG_DEBUG(@"Pixel format: %s (%d)", av_get_pix_fmt_name(pFrame->format), pFrame->format);
  LOG_DEBUG(@"Color range: %s (%d)", av_color_range_name(pFrame->color_range), pFrame->color_range);
  LOG_DEBUG(@"Color primaries: %s (%d)", av_color_primaries_name(pFrame->color_primaries), pFrame->color_primaries);
  LOG_DEBUG(@"Color transfer: %s (%d)", av_color_transfer_name(pFrame->color_trc), pFrame->color_trc);
  LOG_DEBUG(@"Color space: %s (%d)", av_color_space_name(pFrame->colorspace), pFrame->colorspace);
  LOG_DEBUG(@"Width: %d", pFrame->width);
  LOG_DEBUG(@"Height: %d", pFrame->height);
}
#endif

@end
