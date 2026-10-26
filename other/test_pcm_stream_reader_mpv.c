// Plays <media> from <start> for <length> seconds with the bundled libmpv, without video, and
// writes mpv's audio as raw 48 kHz s16 stereo to <out>. Prints mpv's demuxer-start-time, the
// origin of its timeline.
//
//   test_pcm_stream_reader_mpv <media> <aid> <start> <length> <out.raw>
#include <mpv/client.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc != 6) {
    fprintf(stderr, "usage: %s <media> <aid> <start> <length> <out.raw>\n", argv[0]);
    return 2;
  }
  mpv_handle *mpv = mpv_create();
  if (mpv == NULL) return 1;
  const char *options[][2] = {
    {"config", "no"}, {"terminal", "no"}, {"vo", "null"}, {"vid", "no"}, {"sid", "no"},
    {"ao", "pcm"}, {"ao-pcm-file", argv[5]}, {"ao-pcm-waveheader", "no"},
    {"audio-samplerate", "48000"}, {"audio-channels", "stereo"}, {"audio-format", "s16"},
    {"aid", argv[2]}, {"start", argv[3]}, {"length", argv[4]}, {"untimed", "yes"},
  };
  for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
    if (mpv_set_option_string(mpv, options[i][0], options[i][1]) < 0) {
      fprintf(stderr, "option %s rejected\n", options[i][0]);
      return 1;
    }
  }
  if (mpv_initialize(mpv) < 0) return 1;
  const char *command[] = {"loadfile", argv[1], NULL};
  mpv_command(mpv, command);
  int status = 1;
  for (;;) {
    mpv_event *event = mpv_wait_event(mpv, 30);
    if (event->event_id == MPV_EVENT_FILE_LOADED) {
      double start = 0;
      if (mpv_get_property(mpv, "demuxer-start-time", MPV_FORMAT_DOUBLE, &start) >= 0) {
        printf("demuxer-start-time=%.6f\n", start);
        status = 0;
      }
    }
    if (event->event_id == MPV_EVENT_END_FILE || event->event_id == MPV_EVENT_SHUTDOWN ||
        event->event_id == MPV_EVENT_NONE) {
      break;
    }
  }
  mpv_terminate_destroy(mpv);
  return status;
}
