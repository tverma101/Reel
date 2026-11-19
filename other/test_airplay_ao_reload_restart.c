// Driver for test_airplay_ao_reload_restart.py. Starts <media> at <start> with the silent `null`
// audio output and, once mpv has opened that output but before playback has restarted, switches
// `ao` and reloads it as the AirPlay bridge does. With <refresh> 1 it then seeks in place, as the
// bridge does when a reply shows that the switch landed in that window.
//
//   test_airplay_ao_reload_restart <media> <start> <refresh: 0|1>
//
// Prints `window=hit` when the reload ran while mpv was still restarting (else `window=missed`),
// then `restarted=1` if playback restarted within three seconds.
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s <media> <start> <refresh: 0|1>\n", argv[0]);
    return 2;
  }
  mpv_handle *mpv = mpv_create();
  if (mpv == NULL) return 1;
  const char *options[][2] = {
    {"config", "no"}, {"terminal", "no"}, {"vo", "null"}, {"ao", "null"}, {"sid", "no"},
    {"start", argv[2]}, {"hr-seek", "yes"}, {"pause", "no"},
  };
  for (size_t i = 0; i < sizeof(options) / sizeof(options[0]); i++) {
    if (mpv_set_option_string(mpv, options[i][0], options[i][1]) < 0) {
      fprintf(stderr, "option %s rejected\n", options[i][0]);
      return 1;
    }
  }
  if (mpv_initialize(mpv) < 0) return 1;
  mpv_observe_property(mpv, 0, "current-ao", MPV_FORMAT_STRING);
  const char *load[] = {"loadfile", argv[1], NULL};
  mpv_command(mpv, load);

  int sent = 0, restarted = 0, idle = 0;
  while (idle < 300 && !restarted) {
    mpv_event *event = mpv_wait_event(mpv, 0.01);
    if (event->event_id == MPV_EVENT_SHUTDOWN || event->event_id == MPV_EVENT_END_FILE) break;
    if (event->event_id == MPV_EVENT_PLAYBACK_RESTART && sent) restarted = 1;
    if (event->event_id == MPV_EVENT_PLAYBACK_RESTART && !sent) {
      printf("window=missed\n");
      break;
    }
    if (event->event_id == MPV_EVENT_PROPERTY_CHANGE && !sent) {
      mpv_event_property *property = event->data;
      if (property->format == MPV_FORMAT_STRING && *(char **)property->data != NULL) {
        const char *set[] = {"set", "ao", "null", NULL};
        const char *reload[] = {"ao-reload", NULL};
        mpv_command(mpv, set);
        mpv_command(mpv, reload);
        int seeking = 0;
        mpv_get_property(mpv, "seeking", MPV_FORMAT_FLAG, &seeking);
        printf("window=%s\n", seeking ? "hit" : "missed");
        if (!seeking) break;
        if (atoi(argv[3])) {
          const char *seek[] = {"seek", "0", "relative+exact", NULL};
          mpv_command(mpv, seek);
        }
        sent = 1;
      }
    }
    if (sent) idle++;
  }
  printf("restarted=%d\n", restarted);
  mpv_terminate_destroy(mpv);
  return 0;
}
