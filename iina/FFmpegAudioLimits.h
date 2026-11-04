#ifndef REEL_FFMPEG_AUDIO_LIMITS_H
#define REEL_FFMPEG_AUDIO_LIMITS_H

#include <stdint.h>

// Aggregate decoded channel-samples permitted for a caption frame. The bundled FFmpeg's decoder
// allocation guard applies AVCodecContext.max_samples to the aggregate across channels and accepts
// the configured value itself, rejecting only larger frames.
// At 524,288 aggregate samples, even AV_SAMPLE_FMT_DBLP output is bounded to about 4 MiB.
#define REEL_AUDIO_MAX_DECODED_CHANNEL_SAMPLES INT64_C(524288)

#endif
