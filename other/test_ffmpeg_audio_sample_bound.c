#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/log.h>
#include <libavutil/mem.h>

#include "FFmpegAudioLimits.h"

#include <stdio.h>
#include <string.h>

static int check_frame(int channels, int samples_per_channel, int should_decode) {
  const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_PCM_S16LE);
  AVCodecContext *context = codec ? avcodec_alloc_context3(codec) : NULL;
  if (context == NULL) return 2;

  context->sample_rate = 48000;
  // The bundled FFmpeg allocation guard rejects aggregate channel-samples only when they exceed
  // max_samples, so setting the exact budget accepts the limit and rejects budget plus one.
  context->max_samples = REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES;
  context->thread_count = 1;
  av_channel_layout_default(&context->ch_layout, channels);
  if (avcodec_open2(context, codec, NULL) < 0) {
    avcodec_free_context(&context);
    return 3;
  }

  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  if (packet == NULL || frame == NULL ||
      av_new_packet(packet, samples_per_channel * channels * 2) < 0) {
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    return 4;
  }
  memset(packet->data, 0, packet->size);
  int result = avcodec_send_packet(context, packet);
  if (result >= 0) result = avcodec_receive_frame(context, frame);
  int decoded = result >= 0;
  int expected_samples = samples_per_channel * channels;
  fprintf(stdout, "channels=%d samples_per_channel=%d total_samples=%d decoded=%d\n",
          channels, samples_per_channel, expected_samples, decoded);

  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&context);
  return decoded == should_decode ? 0 : 1;
}

int main(void) {
  av_log_set_level(AV_LOG_QUIET);
  int result = 0;
  // Mono can represent every aggregate sample count, including the exact cap + 1 boundary.
  result |= check_frame(1, (int)REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES, 1);
  result |= check_frame(1, (int)REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES + 1, 0);
  // Regression: the previous 48,000-sample cap rejected this valid 6-channel frame.
  result |= check_frame(6, 8192, 1);
  // At six channels the largest whole per-channel frame below the aggregate cap is accepted.
  result |= check_frame(6, (int)(REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES / 6), 1);
  result |= check_frame(6, (int)(REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES / 6) + 1, 0);
  // The cap is channel-inclusive and exact at its boundary.
  result |= check_frame(8, (int)(REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES / 8), 1);
  result |= check_frame(8, (int)(REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES / 8) + 1, 0);
  // Exercise the maximum supported stream layout to ensure the decoder cap is divided by channels.
  result |= check_frame(32, (int)(REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES / 32), 1);
  result |= check_frame(32, (int)(REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES / 32) + 1, 0);
  return result;
}
