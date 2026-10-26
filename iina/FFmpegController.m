//
//  FFmpegController.m
//  iina
//
//  Created by lhc on 9/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

#import "FFmpegController.h"
#import <Accelerate/Accelerate.h>
#import <Cocoa/Cocoa.h>
#include <errno.h>
#include <limits.h>
#import "FFmpegAudioLimits.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#import <libavcodec/avcodec.h>
#import <libavformat/avformat.h>
#import <libswscale/swscale.h>
#import <libavutil/imgutils.h>
#import <libavutil/mastering_display_metadata.h>
#import <libswresample/swresample.h>
#pragma clang diagnostic pop

#import "Reel-Swift.h"

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

- (int)getPeeksForFile:(NSString *)file thumbnailsWidth:(int)thumbnailsWidth;
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
  [_queue cancelAllOperations];
  NSBlockOperation *op = [[NSBlockOperation alloc] init];
  __weak NSBlockOperation *weakOp = op;
  [op addExecutionBlock:^(){
    if ([weakOp isCancelled]) {
      return;
    }
    self->_timestamp = CACurrentMediaTime();
    int success = [self getPeeksForFile:file thumbnailsWidth:thumbWidth];
    if (self.delegate) {
      [self.delegate didGenerateThumbnails:[NSArray arrayWithArray:self->_thumbnails]
                                   forFile: file
                                 succeeded:(success < 0 ? NO : YES)];
    }
  }];
  [_queue addOperation:op];
}

- (int)getPeeksForFile:(NSString *)file
       thumbnailsWidth:(int)thumbnailsWidth
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
  pFrameRGB->format = AV_PIX_FMT_RGBA;

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

  // Get duration and interval
  int64_t duration = av_rescale_q(pFormatCtx->duration, AV_TIME_BASE_Q, pVideoStream->time_base);
  double interval = duration / (double)self.thumbnailCount;
  double timebaseDouble = av_q2d(pVideoStream->time_base);
  AVPacket packet;

  // For each preview point
  for (i = 0; i <= self.thumbnailCount; i++) {
    int64_t seek_pos = interval * i + pVideoStream->start_time;

    avcodec_flush_buffers(pCodecCtx);

    // Seek to time point
    // avformat_seek_file(pFormatCtx, videoStream, seek_pos-interval, seek_pos, seek_pos+interval, 0);
    ret = av_seek_frame(pFormatCtx, videoStream, seek_pos, AVSEEK_FLAG_BACKWARD);
    CHECK_SUCCESS(ret, @"Cannot seek")

    avcodec_flush_buffers(pCodecCtx);

    // Read and decode frame
    while(av_read_frame(pFormatCtx, &packet) >= 0) {
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
          ret = sws_scale(sws_ctx,
                          (const uint8_t* const *)pFrame->data,
                          pFrame->linesize,
                          0,
                          pCodecCtx->height,
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


- (void)saveThumbnail:(AVFrame *)pFrame width
                     :(int)width height
                     :(int)height index
                     :(int)index realTime
                     :(int)second forFile
                     :(NSString *)file
{
  // Create CGImage
  CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();

  CGContextRef cgContext = CGBitmapContextCreate(pFrame->data[0],  // it's converted to RGBA so could be used directly
                                                 width, height,
                                                 8,  // 8 bit per component
                                                 width * 4,  // 4 bytes(rgba) per pixel
                                                 rgb,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGImageRef cgImage = CGBitmapContextCreateImage(cgContext);

  // Create NSImage
  NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size: NSZeroSize];

  // Free resources
  CFRelease(rgb);
  CFRelease(cgContext);
  CFRelease(cgImage);

  // Add to list
  FFThumbnail *tb = [[FFThumbnail alloc] init];
  tb.image = image;
  tb.realTime = second;
  [_thumbnails addObject:tb];
  [_thumbnailPartialResult addObject:tb];
  // Post update notification
  double currentTime = CACurrentMediaTime();
  if (currentTime - _timestamp >= 0.2) {  // min notification interval: 0.2s
    if (_thumbnailPartialResult.count >= 10 || (currentTime - _timestamp >= 1 && _thumbnailPartialResult.count > 0)) {
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

  // In addition to the duration IINA is interested metadata tags, especially the title tag. In many
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

// MARK: - Reading Audio for Local Subtitle Matching

+ (NSData *)readMonoAudioFromFile:(nonnull NSString *)file
                         startTime:(double)startTime
                          duration:(double)duration
                cancellationCheck:(nullable BOOL (^)(void))cancellationCheck
{
  FFmpegAudioChunkReader *reader = [[FFmpegAudioChunkReader alloc] initWithSource:file
                                                                 cancellationCheck:cancellationCheck];
  return [reader readMonoAudioFrom:startTime duration:duration cancellationCheck:cancellationCheck];
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
      // this is all IINA checks as well. ID3v2 defines picture types, but I did not find any code
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

// MARK: - FFmpegAudioChunkReader

static int FFmpegAudioChunkReaderInterrupt(void *opaque);
static const double FFmpegAudioChunkMaximumDuration = 12.0;

@interface FFmpegAudioChunkReader () {
  AVFormatContext *formatContext;
  AVCodecContext *decoder;
  SwrContext *resampler;
  int audioStreamIndex;
  double mediaOrigin;
}
@property (nonatomic, copy, nullable) BOOL (^cancellationCheck)(void);
@property (nonatomic, readwrite) BOOL failed;
@property (nonatomic, readwrite) BOOL seekUnsupported;
- (nullable instancetype)initWithSource:(nonnull NSString *)source
              requestedAudioStreamIndex:(NSInteger)requestedAudioStreamIndex
                     cancellationCheck:(nullable BOOL (^)(void))cancellationCheck;
@end

static int FFmpegAudioChunkReaderInterrupt(void *opaque) {
  FFmpegAudioChunkReader *reader = (__bridge FFmpegAudioChunkReader *)opaque;
  BOOL (^check)(void) = reader.cancellationCheck;
  return check != nil && check() ? 1 : 0;
}

@implementation FFmpegAudioChunkReader

- (nullable instancetype)initWithSource:(nonnull NSString *)source
                      cancellationCheck:(nullable BOOL (^)(void))cancellationCheck
{
  return [self initWithSource:source requestedAudioStreamIndex:-1 cancellationCheck:cancellationCheck];
}

- (nullable instancetype)initWithSource:(nonnull NSString *)source
                       audioStreamIndex:(NSInteger)selectedAudioStreamIndex
                      cancellationCheck:(nullable BOOL (^)(void))cancellationCheck
{
  if (selectedAudioStreamIndex < 0) {
    return nil;
  }
  return [self initWithSource:source
     requestedAudioStreamIndex:selectedAudioStreamIndex
            cancellationCheck:cancellationCheck];
}

- (nullable instancetype)initWithSource:(nonnull NSString *)source
              requestedAudioStreamIndex:(NSInteger)requestedAudioStreamIndex
                     cancellationCheck:(nullable BOOL (^)(void))cancellationCheck
{
  self = [super init];
  if (self == nil || source.length == 0 || requestedAudioStreamIndex < -1 ||
      requestedAudioStreamIndex > INT_MAX) {
    return nil;
  }
  const BOOL useBestAudioStream = requestedAudioStreamIndex == -1;
  audioStreamIndex = useBestAudioStream ? -1 : (int)requestedAudioStreamIndex;
  _cancellationCheck = [cancellationCheck copy];

  // Network streams are opened by URL with bounded I/O timeouts; anything else is a local path.
  NSString *scheme = [NSURL URLWithString:source].scheme.lowercaseString;
  BOOL isNetworkStream = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
  AVDictionary *openOptions = NULL;
  if (isNetworkStream) {
    av_dict_set(&openOptions, "rw_timeout", "10000000", 0);
    av_dict_set(&openOptions, "reconnect", "1", 0);
    av_dict_set(&openOptions, "reconnect_max_retries", "2", 0);
    av_dict_set(&openOptions, "reconnect_delay_max", "1", 0);
    av_dict_set(&openOptions, "reconnect_delay_total_max", "3", 0);
    av_dict_set(&openOptions, "protocol_whitelist", "http,https,tcp,tls", 0);
  }

  if (_cancellationCheck != nil && _cancellationCheck()) {
    av_dict_free(&openOptions);
    return nil;
  }
  formatContext = avformat_alloc_context();
  if (formatContext == NULL) {
    av_dict_free(&openOptions);
    return nil;
  }
  formatContext->interrupt_callback.callback = FFmpegAudioChunkReaderInterrupt;
  formatContext->interrupt_callback.opaque = (__bridge void *)self;
  int ret = avformat_open_input(&formatContext,
                                isNetworkStream ? source.UTF8String : source.fileSystemRepresentation,
                                NULL, &openOptions);
  av_dict_free(&openOptions);
  if (ret < 0) {
    return nil;  // avformat_open_input frees the context on failure.
  }
  if (_cancellationCheck != nil && _cancellationCheck()) {
    return nil;
  }

  if (useBestAudioStream) {
    audioStreamIndex = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
  }
  AVCodecParameters *params = audioStreamIndex >= 0 &&
    (unsigned int)audioStreamIndex < formatContext->nb_streams
    ? formatContext->streams[audioStreamIndex]->codecpar : NULL;
  if (!useBestAudioStream && (params == NULL || params->codec_type != AVMEDIA_TYPE_AUDIO)) {
    return nil;
  }
  // Containers such as MP4 describe the audio fully in their header. Probing packets would also
  // download video data, which for a network stream costs seconds, so only probe when needed.
  BOOL needsProbe = params == NULL || params->sample_rate <= 0 || params->ch_layout.nb_channels <= 0;
  if (needsProbe) {
    if (avformat_find_stream_info(formatContext, NULL) < 0) {
      return nil;
    }
    if (_cancellationCheck != nil && _cancellationCheck()) {
      return nil;
    }
    if (useBestAudioStream) {
      audioStreamIndex = av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    } else if ((unsigned int)audioStreamIndex >= formatContext->nb_streams ||
               formatContext->streams[audioStreamIndex]->codecpar == NULL ||
               formatContext->streams[audioStreamIndex]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
      return nil;
    }
  }
  if (audioStreamIndex < 0 || (unsigned int)audioStreamIndex >= formatContext->nb_streams) {
    return nil;
  }
  for (unsigned int index = 0; index < formatContext->nb_streams; index++) {
    if ((int)index != audioStreamIndex) {
      formatContext->streams[index]->discard = AVDISCARD_ALL;
    }
  }

  AVStream *audioStream = formatContext->streams[audioStreamIndex];
  const AVCodec *codec = avcodec_find_decoder(audioStream->codecpar->codec_id);
  if (codec == NULL) {
    return nil;
  }
  decoder = avcodec_alloc_context3(codec);
  if (decoder == NULL || avcodec_parameters_to_context(decoder, audioStream->codecpar) < 0 ||
      decoder->sample_rate <= 0 || decoder->ch_layout.nb_channels <= 0 ||
      decoder->ch_layout.nb_channels > 32) {
    return nil;
  }
  // Captions decode excerpts on a single serial queue; parallel decoder workers increase peak
  // memory without helping the one-at-a-time 12-second workload. Reject pathological decoded
  // frames before libavcodec allocates them so the later PCM cap is not the only memory guard.
  decoder->thread_count = 1;
  decoder->thread_type = 0;
  // The bundled FFmpeg allocation guard compares aggregate channel-samples against max_samples
  // and rejects only larger frames, so the exact aggregate budget is safe to accept.
  decoder->max_samples = REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES;
  if (decoder->max_samples <= 0 || avcodec_open2(decoder, codec, NULL) < 0) {
    return nil;
  }
  if (_cancellationCheck != nil && _cancellationCheck()) {
    return nil;
  }

  AVChannelLayout outputLayout;
  memset(&outputLayout, 0, sizeof(outputLayout));
  av_channel_layout_default(&outputLayout, 1);
  ret = swr_alloc_set_opts2(&resampler, &outputLayout, AV_SAMPLE_FMT_FLT, 16000,
                            &decoder->ch_layout, decoder->sample_fmt, decoder->sample_rate, 0, NULL);
  av_channel_layout_uninit(&outputLayout);
  if (ret < 0 || resampler == NULL || swr_init(resampler) < 0) {
    return nil;
  }

  if (formatContext->start_time != AV_NOPTS_VALUE) {
    mediaOrigin = (double)formatContext->start_time / AV_TIME_BASE;
  }
  _cancellationCheck = nil;
  return self;
}

- (void)dealloc
{
  if (resampler != NULL) swr_free(&resampler);
  if (decoder != NULL) avcodec_free_context(&decoder);
  if (formatContext != NULL) avformat_close_input(&formatContext);
}

- (nullable NSData *)readMonoAudioFrom:(double)startTime
                              duration:(double)duration
                     cancellationCheck:(nullable BOOL (^)(void))cancellationCheck
{
  if (_failed || !isfinite(startTime) || !isfinite(duration) || startTime < 0 || duration <= 0 ||
      duration > FFmpegAudioChunkMaximumDuration) {
    return nil;
  }
  double sampleEnd = startTime + duration;
  double seekTime = mediaOrigin + MAX(0, startTime - 0.5);
  long double seekUnits = (long double)seekTime * AV_TIME_BASE;
  if (!isfinite(sampleEnd) || sampleEnd <= startTime || !isfinite(seekTime) ||
      !isfinite(seekUnits) || seekUnits > INT64_MAX || seekUnits < INT64_MIN) {
    return nil;
  }
  NSUInteger maximumOutputSamples = (NSUInteger)ceil(duration * 16000.0);
  if (maximumOutputSamples > NSUIntegerMax / sizeof(float)) {
    return nil;
  }
  NSUInteger maximumOutputBytes = maximumOutputSamples * sizeof(float);

  self.cancellationCheck = cancellationCheck;
  if (cancellationCheck != nil && cancellationCheck()) {
    _failed = YES;
    self.cancellationCheck = nil;
    return nil;
  }
  NSMutableData *output = [NSMutableData data];
  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  BOOL reachedEnd = NO;
  int readResult = 0;
  AVStream *audioStream = formatContext->streams[audioStreamIndex];

  if (audioStream->time_base.num <= 0 || audioStream->time_base.den <= 0) {
    _failed = YES;
    goto cleanup;
  }
  int64_t seekTimestamp = av_rescale_q((int64_t)llroundl(seekUnits),
                                       AV_TIME_BASE_Q, audioStream->time_base);
  if (seekTimestamp == INT64_MIN || seekTimestamp == INT64_MAX) {
    _failed = YES;
    goto cleanup;
  }
  BOOL attemptedSeek = packet != NULL && frame != NULL;
  int seekResult = attemptedSeek
    ? avformat_seek_file(formatContext, audioStreamIndex, INT64_MIN, seekTimestamp,
                         seekTimestamp, AVSEEK_FLAG_BACKWARD)
    : AVERROR(ENOMEM);
  if (seekResult < 0) {
    _failed = YES;
    BOOL interrupted = cancellationCheck != nil && cancellationCheck();
    BOOL nonseekableIO = formatContext->pb != NULL &&
      (formatContext->pb->seekable & AVIO_SEEKABLE_NORMAL) == 0;
    if (attemptedSeek && !interrupted &&
        (seekResult == AVERROR(ENOSYS) || seekResult == AVERROR(ESPIPE) || nonseekableIO)) {
      self.seekUnsupported = YES;
    }
    goto cleanup;
  }
  avcodec_flush_buffers(decoder);
  // Drop samples buffered from the previous chunk; this chunk starts at a new position.
  swr_close(resampler);
  if (swr_init(resampler) < 0 || (cancellationCheck != nil && cancellationCheck())) {
    _failed = YES;
    goto cleanup;
  }

  while (!reachedEnd && !(cancellationCheck && cancellationCheck()) &&
         (readResult = av_read_frame(formatContext, packet)) >= 0) {
    if (packet->stream_index == audioStreamIndex && avcodec_send_packet(decoder, packet) >= 0) {
      while (!reachedEnd && !(cancellationCheck && cancellationCheck()) &&
             avcodec_receive_frame(decoder, frame) >= 0) {
        if (frame->best_effort_timestamp == AV_NOPTS_VALUE) {
          av_frame_unref(frame);
          continue;
        }
        double frameStart = frame->best_effort_timestamp * av_q2d(audioStream->time_base) - mediaOrigin;
        double frameEnd = frameStart + (double)frame->nb_samples / decoder->sample_rate;
        if (!isfinite(frameStart) || !isfinite(frameEnd) || frame->nb_samples < 0) {
          _failed = YES;
          goto cleanup;
        }
        if (frameStart > sampleEnd + 1.0) {
          reachedEnd = YES;
          av_frame_unref(frame);
          break;
        }
        if (frameEnd >= startTime - 0.1 && frameStart <= sampleEnd + 0.1) {
          int64_t outputCapacityValue = av_rescale_rnd(swr_get_delay(resampler, decoder->sample_rate) + frame->nb_samples,
                                                       16000, decoder->sample_rate, AV_ROUND_UP);
          // Keep a single decoded frame's temporary float buffer bounded too. Normal audio frames
          // are far below this; an absurd frame is safer to reject than to allocate from its size.
          int64_t maximumFrameSamples = (int64_t)maximumOutputSamples + 16000;
          if (outputCapacityValue < 0 || outputCapacityValue > maximumFrameSamples) {
            _failed = YES;
            goto cleanup;
          }
          int outputCapacity = (int)outputCapacityValue;
          if (outputCapacity > 0) {
            float *samples = av_malloc_array(outputCapacity, sizeof(float));
            if (samples == NULL) {
              _failed = YES;
              goto cleanup;
            }
            uint8_t *outputPlanes[] = {(uint8_t *)samples};
            int outputSamples = swr_convert(resampler, outputPlanes, outputCapacity,
                                            (const uint8_t **)frame->extended_data, frame->nb_samples);
            if (outputSamples > 0) {
              double firstSample = floor((startTime - frameStart) * 16000.0);
              double lastSample = ceil((sampleEnd - frameStart) * 16000.0);
              if (!isfinite(firstSample) || !isfinite(lastSample)) {
                av_free(samples);
                _failed = YES;
                goto cleanup;
              }
              int first = (int)fmin(outputSamples, fmax(0.0, firstSample));
              int last = (int)fmin(outputSamples, fmax(0.0, lastSample));
              if (last > first) {
                NSUInteger requestedBytes = (NSUInteger)(last - first) * sizeof(float);
                NSUInteger remainingBytes = maximumOutputBytes - output.length;
                NSUInteger appendBytes = MIN(requestedBytes, remainingBytes);
                appendBytes -= appendBytes % sizeof(float);
                if (appendBytes > 0) {
                  [output appendBytes:samples + first length:appendBytes];
                }
                if (output.length >= maximumOutputBytes) {
                  reachedEnd = YES;
                }
              }
            } else if (outputSamples < 0) {
              av_free(samples);
              _failed = YES;
              goto cleanup;
            }
            av_free(samples);
          }
        }
        av_frame_unref(frame);
      }
    }
    av_packet_unref(packet);
  }
  // A read error other than the end of the media (for example a dropped connection) leaves the
  // demuxer in an unknown state; the owner should open a new reader.
  if (readResult < 0 && readResult != AVERROR_EOF && !(cancellationCheck && cancellationCheck())) {
    _failed = YES;
  }

cleanup:
  if (cancellationCheck != nil && cancellationCheck()) {
    // A timed out or cancelled read must never pass partial speech to the recognizer.
    _failed = YES;
    [output setLength:0];
  }
  if (frame != NULL) av_frame_free(&frame);
  if (packet != NULL) av_packet_free(&packet);
  self.cancellationCheck = nil;
  return !_failed && output.length >= sizeof(float) * 16000 ? [output copy] : nil;
}

@end

// MARK: - FFmpegPCMStreamReader

static const int FFmpegPCMStreamSampleRate = 48000;
static const int FFmpegPCMStreamChannels = 2;
static const NSUInteger FFmpegPCMStreamFrameBytes = FFmpegPCMStreamChannels * sizeof(int16_t);
static const NSInteger FFmpegPCMStreamMaximumReadFrames = 10 * FFmpegPCMStreamSampleRate;
/// Container timestamps are rounded (Matroska to the millisecond), so small disagreements with the
/// decoded sample count are not gaps or overlaps.
static const int64_t FFmpegPCMStreamTimestampTolerance = FFmpegPCMStreamSampleRate / 50;
/// A read this far ahead of the decoded audio decodes through instead of seeking.
static const int64_t FFmpegPCMStreamMaximumSkipFrames = 2 * FFmpegPCMStreamSampleRate;

static int FFmpegPCMStreamReaderInterrupt(void *opaque);

@interface FFmpegPCMStreamReader () {
  AVFormatContext *formatContext;
  AVCodecContext *decoder;
  SwrContext *resampler;
  AVChannelLayout resamplerInputLayout;
  int resamplerInputRate;
  int resamplerInputFormat;
  AVPacket *packet;
  AVFrame *frame;
  int audioStreamIndex;
  /// The stream whose index seeks use: Matroska files usually index only their video.
  int seekStreamIndex;
  double mediaOrigin;
  /// Decoded audio not yet returned. Its first frame is `bufferStart`.
  NSMutableData *buffer;
  int64_t bufferStart;
  /// Timeline frame of the next decoded sample. Below `bufferStart` while decoding through a skip.
  int64_t nextFrame;
  /// After a seek the first decoded frame is placed by its timestamp alone.
  BOOL aligning;
  BOOL inputEnded;
  BOOL endOfStream;
  /// Decoded samples waiting behind a long gap, and their timeline frame.
  NSData *parkedSamples;
  int64_t parkedPlace;
  /// Scratch output for swr_convert, grown as needed and reused instead of allocated per frame.
  int16_t *conversionBuffer;
  int conversionCapacity;
}
@property (nonatomic, copy, nullable) BOOL (^cancellationCheck)(void);
@property (nonatomic, readwrite) BOOL failed;
@property (nonatomic, readwrite) double duration;
@end

static int FFmpegPCMStreamReaderInterrupt(void *opaque) {
  FFmpegPCMStreamReader *reader = (__bridge FFmpegPCMStreamReader *)opaque;
  BOOL (^check)(void) = reader.cancellationCheck;
  return check != nil && check() ? 1 : 0;
}

@implementation FFmpegPCMStreamReader

+ (NSInteger)sampleRate { return FFmpegPCMStreamSampleRate; }
+ (NSInteger)channelCount { return FFmpegPCMStreamChannels; }

- (nullable instancetype)initWithSource:(nonnull NSString *)source
                       audioStreamIndex:(NSInteger)requestedAudioStreamIndex
                            mediaOrigin:(nullable NSNumber *)requestedMediaOrigin
                      cancellationCheck:(nullable BOOL (^)(void))cancellationCheck
{
  self = [super init];
  if (self == nil || source.length == 0 || requestedAudioStreamIndex < 0 ||
      requestedAudioStreamIndex > INT_MAX) {
    return nil;
  }
  audioStreamIndex = (int)requestedAudioStreamIndex;
  resamplerInputRate = -1;
  resamplerInputFormat = -1;
  buffer = [NSMutableData data];
  _cancellationCheck = [cancellationCheck copy];

  NSString *scheme = [NSURL URLWithString:source].scheme.lowercaseString;
  BOOL isNetworkStream = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
  AVDictionary *openOptions = NULL;
  if (isNetworkStream) {
    av_dict_set(&openOptions, "rw_timeout", "10000000", 0);
    av_dict_set(&openOptions, "reconnect", "1", 0);
    av_dict_set(&openOptions, "reconnect_max_retries", "2", 0);
    av_dict_set(&openOptions, "reconnect_delay_max", "1", 0);
    av_dict_set(&openOptions, "reconnect_delay_total_max", "3", 0);
    av_dict_set(&openOptions, "protocol_whitelist", "http,https,tcp,tls", 0);
  }
  if (_cancellationCheck != nil && _cancellationCheck()) {
    av_dict_free(&openOptions);
    return nil;
  }
  formatContext = avformat_alloc_context();
  if (formatContext == NULL) {
    av_dict_free(&openOptions);
    return nil;
  }
  formatContext->interrupt_callback.callback = FFmpegPCMStreamReaderInterrupt;
  formatContext->interrupt_callback.opaque = (__bridge void *)self;
  int ret = avformat_open_input(&formatContext,
                                isNetworkStream ? source.UTF8String : source.fileSystemRepresentation,
                                NULL, &openOptions);
  av_dict_free(&openOptions);
  if (ret < 0) {
    return nil;  // avformat_open_input frees the context on failure.
  }
  if (_cancellationCheck != nil && _cancellationCheck()) {
    return nil;
  }
  AVCodecParameters *params = (unsigned int)audioStreamIndex < formatContext->nb_streams
    ? formatContext->streams[audioStreamIndex]->codecpar : NULL;
  if (params == NULL || params->codec_type != AVMEDIA_TYPE_AUDIO) {
    return nil;
  }
  if (params->sample_rate <= 0 || params->ch_layout.nb_channels <= 0) {
    if (avformat_find_stream_info(formatContext, NULL) < 0 ||
        (_cancellationCheck != nil && _cancellationCheck())) {
      return nil;
    }
  }
  seekStreamIndex = audioStreamIndex;
  for (unsigned int index = 0; index < formatContext->nb_streams; index++) {
    AVStream *stream = formatContext->streams[index];
    if (seekStreamIndex == audioStreamIndex && stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO &&
        !(stream->disposition & AV_DISPOSITION_ATTACHED_PIC) &&
        stream->time_base.num > 0 && stream->time_base.den > 0) {
      seekStreamIndex = (int)index;
    }
    if ((int)index != audioStreamIndex) {
      stream->discard = AVDISCARD_ALL;
    }
  }

  AVStream *audioStream = formatContext->streams[audioStreamIndex];
  if (audioStream->time_base.num <= 0 || audioStream->time_base.den <= 0) {
    return nil;
  }
  const AVCodec *codec = avcodec_find_decoder(audioStream->codecpar->codec_id);
  if (codec == NULL) {
    return nil;
  }
  decoder = avcodec_alloc_context3(codec);
  if (decoder == NULL || avcodec_parameters_to_context(decoder, audioStream->codecpar) < 0 ||
      decoder->ch_layout.nb_channels > 32) {
    return nil;
  }
  decoder->pkt_timebase = audioStream->time_base;
  decoder->thread_count = 1;
  decoder->thread_type = 0;
  // Reject pathological frames before libavcodec allocates them, as the caption reader does.
  decoder->max_samples = REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES;
  if (avcodec_open2(decoder, codec, NULL) < 0) {
    return nil;
  }
  packet = av_packet_alloc();
  frame = av_frame_alloc();
  if (packet == NULL || frame == NULL) {
    return nil;
  }
  if (requestedMediaOrigin != nil) {
    mediaOrigin = requestedMediaOrigin.doubleValue;
    if (!isfinite(mediaOrigin) || fabs(mediaOrigin) > 1e7) {
      return nil;
    }
  } else if (formatContext->start_time != AV_NOPTS_VALUE) {
    mediaOrigin = (double)formatContext->start_time / AV_TIME_BASE;
  }
  if (formatContext->duration != AV_NOPTS_VALUE && formatContext->duration > 0) {
    _duration = (double)formatContext->duration / AV_TIME_BASE;
  } else if (audioStream->duration != AV_NOPTS_VALUE && audioStream->duration > 0) {
    // Without stream probing, MP4 reports only per-stream durations.
    _duration = audioStream->duration * av_q2d(audioStream->time_base);
  }
  // The first read positions the stream wherever it starts.
  aligning = YES;
  _cancellationCheck = nil;
  return self;
}

- (void)dealloc
{
  av_freep(&conversionBuffer);
  if (frame != NULL) av_frame_free(&frame);
  if (packet != NULL) av_packet_free(&packet);
  if (resampler != NULL) swr_free(&resampler);
  av_channel_layout_uninit(&resamplerInputLayout);
  if (decoder != NULL) avcodec_free_context(&decoder);
  if (formatContext != NULL) avformat_close_input(&formatContext);
}

- (BOOL)isCancelled
{
  return _cancellationCheck != nil && _cancellationCheck();
}

- (int64_t)bufferedFrames
{
  return (int64_t)(buffer.length / FFmpegPCMStreamFrameBytes);
}

- (nullable NSData *)readFramesAt:(int64_t)frameIndex
                            count:(NSInteger)frameCount
                cancellationCheck:(nullable BOOL (^)(void))cancellationCheck
{
  if (_failed || frameIndex < 0 || frameCount <= 0 || frameCount > FFmpegPCMStreamMaximumReadFrames) {
    return nil;
  }
  self.cancellationCheck = cancellationCheck;
  NSData *result = [self readFramesAt:frameIndex count:frameCount];
  self.cancellationCheck = nil;
  return result;
}

- (nullable NSData *)readFramesAt:(int64_t)frameIndex count:(NSInteger)frameCount
{
  int64_t bufferEnd = bufferStart + [self bufferedFrames];
  if (frameIndex < bufferStart || frameIndex > MAX(bufferEnd, nextFrame) + FFmpegPCMStreamMaximumSkipFrames) {
    if (![self seekToFrame:frameIndex]) {
      _failed = YES;
      return nil;
    }
  } else if (frameIndex > bufferStart) {
    int64_t drop = MIN(frameIndex, bufferEnd) - bufferStart;
    [buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)drop * FFmpegPCMStreamFrameBytes)
                      withBytes:NULL length:0];
    bufferStart = frameIndex;
  }

  while ([self bufferedFrames] < frameCount) {
    if ([self isCancelled]) {
      _failed = YES;
      return nil;
    }
    if (parkedSamples != nil) {
      NSData *parked = parkedSamples;
      parkedSamples = nil;
      [self appendSamples:parked.bytes count:(int)(parked.length / FFmpegPCMStreamFrameBytes)
           timestampFrame:parkedPlace hasTimestamp:YES];
      continue;
    }
    if (endOfStream) {
      // Past the end of the audio the stream plays silence until the item ends.
      [buffer increaseLengthBy:(NSUInteger)(frameCount - [self bufferedFrames]) * FFmpegPCMStreamFrameBytes];
      nextFrame = bufferStart + [self bufferedFrames];
      break;
    }
    if (![self decodeMore]) {
      _failed = YES;
      return nil;
    }
  }

  NSUInteger length = (NSUInteger)frameCount * FFmpegPCMStreamFrameBytes;
  NSData *result = [buffer subdataWithRange:NSMakeRange(0, length)];
  [buffer replaceBytesInRange:NSMakeRange(0, length) withBytes:NULL length:0];
  bufferStart += frameCount;
  return result;
}

- (BOOL)seekToFrame:(int64_t)target
{
  // Start a little early: decoders need preroll, and a keyframe-less seek can land late.
  double seekTime = mediaOrigin + MAX(0.0, (double)target / FFmpegPCMStreamSampleRate - 0.5);
  long double seekUnits = (long double)seekTime * AV_TIME_BASE;
  if (!isfinite(seekTime) || seekUnits >= 0x1p63L || seekUnits < -0x1p63L) {
    return NO;
  }
  int64_t seekMicroseconds = (int64_t)llroundl(seekUnits);
  if (![self seekStream:seekStreamIndex toTime:seekMicroseconds]) {
    // Containers without an index, such as MPEG-TS, are searched by timestamps, and only the audio
    // stream delivers packets.
    if (seekStreamIndex == audioStreamIndex) return NO;
    seekStreamIndex = audioStreamIndex;
    if (![self seekStream:seekStreamIndex toTime:seekMicroseconds]) return NO;
  }
  avcodec_flush_buffers(decoder);
  // Samples held in the resampler belong to the old position.
  if (resampler != NULL) swr_free(&resampler);
  buffer.length = 0;
  parkedSamples = nil;
  bufferStart = target;
  nextFrame = target;
  aligning = YES;
  inputEnded = NO;
  endOfStream = NO;
  return YES;
}

- (BOOL)seekStream:(int)streamIndex toTime:(int64_t)microseconds
{
  int64_t timestamp = av_rescale_q(microseconds, AV_TIME_BASE_Q, formatContext->streams[streamIndex]->time_base);
  return timestamp != INT64_MIN && timestamp != INT64_MAX &&
    avformat_seek_file(formatContext, streamIndex, INT64_MIN, timestamp, timestamp, AVSEEK_FLAG_BACKWARD) >= 0;
}

/// Decodes one step: a frame out of the decoder or a packet into it. Returns NO on failure.
- (BOOL)decodeMore
{
  int ret = avcodec_receive_frame(decoder, frame);
  if (ret == 0) {
    BOOL appended = [self appendDecodedFrame];
    av_frame_unref(frame);
    return appended;
  }
  if (ret == AVERROR_EOF) {
    [self drainResampler];
    endOfStream = YES;
    return YES;
  }
  if (ret != AVERROR(EAGAIN)) {
    return NO;
  }
  if (inputEnded) {
    endOfStream = YES;
    return YES;
  }
  ret = av_read_frame(formatContext, packet);
  if (ret == AVERROR_EOF) {
    avcodec_send_packet(decoder, NULL);
    inputEnded = YES;
    return YES;
  }
  if (ret < 0) {
    return NO;
  }
  if (packet->stream_index == audioStreamIndex) {
    // A corrupt packet is skipped, as mpv does; the timestamps of the next frame restore the timing.
    avcodec_send_packet(decoder, packet);
  }
  av_packet_unref(packet);
  return YES;
}

- (BOOL)configureResamplerForFrame
{
  AVChannelLayout inputLayout;
  memset(&inputLayout, 0, sizeof(inputLayout));
  if (frame->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || frame->ch_layout.nb_channels <= 0) {
    if (frame->ch_layout.nb_channels <= 0) return NO;
    av_channel_layout_default(&inputLayout, frame->ch_layout.nb_channels);
  } else if (av_channel_layout_copy(&inputLayout, &frame->ch_layout) < 0) {
    return NO;
  }
  if (resampler != NULL && frame->sample_rate == resamplerInputRate && frame->format == resamplerInputFormat &&
      av_channel_layout_compare(&inputLayout, &resamplerInputLayout) == 0) {
    av_channel_layout_uninit(&inputLayout);
    return YES;
  }
  if (resampler != NULL) swr_free(&resampler);
  av_channel_layout_uninit(&resamplerInputLayout);
  AVChannelLayout outputLayout;
  memset(&outputLayout, 0, sizeof(outputLayout));
  av_channel_layout_default(&outputLayout, FFmpegPCMStreamChannels);
  int ret = swr_alloc_set_opts2(&resampler, &outputLayout, AV_SAMPLE_FMT_S16, FFmpegPCMStreamSampleRate,
                                &inputLayout, frame->format, frame->sample_rate, 0, NULL);
  av_channel_layout_uninit(&outputLayout);
  if (ret < 0 || resampler == NULL || swr_init(resampler) < 0) {
    av_channel_layout_uninit(&inputLayout);
    if (resampler != NULL) swr_free(&resampler);
    return NO;
  }
  resamplerInputLayout = inputLayout;
  resamplerInputRate = frame->sample_rate;
  resamplerInputFormat = frame->format;
  return YES;
}

- (BOOL)appendDecodedFrame
{
  if (frame->nb_samples <= 0 || frame->sample_rate <= 0) {
    return YES;
  }
  if (![self configureResamplerForFrame]) {
    return NO;
  }
  BOOL hasTimestamp = frame->best_effort_timestamp != AV_NOPTS_VALUE;
  int64_t timestampFrame = 0;
  if (hasTimestamp) {
    AVStream *audioStream = formatContext->streams[audioStreamIndex];
    double seconds = frame->best_effort_timestamp * av_q2d(audioStream->time_base) - mediaOrigin;
    if (!isfinite(seconds) || fabs(seconds) > 1e7) {
      hasTimestamp = NO;
    } else {
      // Output lags the input by the samples the resampler still holds.
      timestampFrame = llround(seconds * FFmpegPCMStreamSampleRate) -
        swr_get_delay(resampler, FFmpegPCMStreamSampleRate);
    }
  }
  int capacity = swr_get_out_samples(resampler, frame->nb_samples);
  if (capacity < 0 || capacity > FFmpegPCMStreamMaximumReadFrames) {
    return NO;
  }
  if (capacity == 0) {
    return YES;
  }
  int16_t *samples = [self conversionBufferWithCapacity:capacity];
  if (samples == NULL) {
    return NO;
  }
  uint8_t *outputPlanes[] = {(uint8_t *)samples};
  int count = swr_convert(resampler, outputPlanes, capacity,
                          (const uint8_t **)frame->extended_data, frame->nb_samples);
  if (count > 0) {
    [self appendSamples:samples count:count timestampFrame:timestampFrame hasTimestamp:hasTimestamp];
  }
  return count >= 0;
}

/// The scratch buffer `swr_convert` writes into, grown to `capacity` frames and kept for reuse.
- (int16_t *)conversionBufferWithCapacity:(int)capacity
{
  if (conversionBuffer != NULL && capacity <= conversionCapacity) {
    return conversionBuffer;
  }
  av_freep(&conversionBuffer);
  conversionCapacity = 0;
  conversionBuffer = av_malloc_array(capacity, FFmpegPCMStreamFrameBytes);
  if (conversionBuffer == NULL) {
    return NULL;
  }
  conversionCapacity = capacity;
  return conversionBuffer;
}

- (void)drainResampler
{
  if (resampler == NULL) return;
  int capacity = swr_get_out_samples(resampler, 0);
  if (capacity <= 0 || capacity > FFmpegPCMStreamMaximumReadFrames) return;
  int16_t *samples = [self conversionBufferWithCapacity:capacity];
  if (samples == NULL) return;
  uint8_t *outputPlanes[] = {(uint8_t *)samples};
  int count = swr_convert(resampler, outputPlanes, capacity, NULL, 0);
  if (count > 0) {
    [self appendSamples:samples count:count timestampFrame:0 hasTimestamp:NO];
  }
}

/// Places decoded samples on the timeline. A frame whose timestamp is past the expected position
/// is preceded by silence; one before it has its overlap dropped. Samples before `bufferStart`
/// (preroll after a seek, or a short skip) are discarded. A gap longer than one read is filled a
/// read at a time, with the samples after it parked until the silence before them is consumed.
- (void)appendSamples:(const int16_t *)samples count:(int)count
       timestampFrame:(int64_t)timestampFrame hasTimestamp:(BOOL)hasTimestamp
{
  int64_t place = nextFrame;
  if (aligning) {
    if (!hasTimestamp) return;
    place = timestampFrame;
    // `nextFrame` is the seek target until now; preroll before it must not be measured against it.
    nextFrame = MIN(nextFrame, place);
    aligning = NO;
  } else if (hasTimestamp) {
    int64_t difference = timestampFrame - nextFrame;
    // A large backward jump is a timestamp discontinuity, not an overlap to decode through.
    if (difference > FFmpegPCMStreamTimestampTolerance ||
        (difference < -FFmpegPCMStreamTimestampTolerance && difference > -FFmpegPCMStreamMaximumReadFrames)) {
      place = timestampFrame;
    }
  }
  if (place > nextFrame) {
    int64_t silenceStart = MAX(nextFrame, bufferStart);
    if (place - silenceStart > FFmpegPCMStreamMaximumReadFrames) {
      [buffer increaseLengthBy:(NSUInteger)FFmpegPCMStreamMaximumReadFrames * FFmpegPCMStreamFrameBytes];
      nextFrame = silenceStart + FFmpegPCMStreamMaximumReadFrames;
      parkedSamples = [NSData dataWithBytes:samples length:(NSUInteger)count * FFmpegPCMStreamFrameBytes];
      parkedPlace = place;
      return;
    }
    if (place > silenceStart) {
      [buffer increaseLengthBy:(NSUInteger)(place - silenceStart) * FFmpegPCMStreamFrameBytes];
    }
    nextFrame = place;
  }
  int64_t keepFrom = MAX(nextFrame, bufferStart);
  int64_t first = keepFrom - place;
  if (first < count) {
    [buffer appendBytes:samples + first * FFmpegPCMStreamChannels
                 length:(NSUInteger)(count - first) * FFmpegPCMStreamFrameBytes];
  }
  nextFrame = MAX(nextFrame, place + count);
}

@end
