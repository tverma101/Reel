// Driver for test_pcm_stream_reader.py. Built against FFmpegPCMStreamReader extracted from
// iina/FFmpegController.m.
//
//   compare <media> <ffIndex> <origin|nil> <start> <mpv.raw>
//     Compares two seconds of mpv's own output (one second after <start>) with the reader.
//   seeks <media> <ffIndex>
//     Compares seeks, skips and re-reads with one sequential decode, then checks the limits.
#import <Foundation/Foundation.h>
#import "pcm_stream_reader.h"

static const int Rate = 48000;

// Best lag of `b` against `a` within ±maxLag frames, by normalized correlation of the left
// channel. `b` must hold maxLag extra frames on each side.
static void bestLag(const int16_t *a, const int16_t *b, int frames, int maxLag, int *lag, double *corr) {
  double best = -2;
  int found = 0;
  for (int step = 2; step >= 1; step--) {
    int from = step == 2 ? -maxLag : found - 2, to = step == 2 ? maxLag : found + 2;
    for (int l = MAX(from, -maxLag); l <= MIN(to, maxLag); l++) {
      double ab = 0, aa = 0, bb = 0;
      for (int i = 0; i < frames; i += step) {
        double x = a[2 * i], y = b[2 * (i + maxLag + l)];
        ab += x * y; aa += x * x; bb += y * y;
      }
      double c = ab / sqrt(aa * bb + 1e-9);
      if (c > best || (step == 1 && l == found)) {
        if (c >= best) { best = c; found = l; }
      }
    }
  }
  *lag = found;
  *corr = best;
}

static NSData *readAt(FFmpegPCMStreamReader *reader, int64_t frame, NSInteger count) {
  return [reader readFramesAt:frame count:count cancellationCheck:nil];
}

static int compareWithMPV(const char **argv) {
  NSNumber *origin = strcmp(argv[4], "nil") == 0 ? nil : @(atof(argv[4]));
  FFmpegPCMStreamReader *reader = [[FFmpegPCMStreamReader alloc] initWithSource:@(argv[2])
                                                               audioStreamIndex:atoi(argv[3])
                                                                    mediaOrigin:origin
                                                              cancellationCheck:nil];
  NSData *mpv = [NSData dataWithContentsOfFile:@(argv[6])];
  const int window = 2 * Rate, maxLag = Rate * 15 / 100;
  if (reader == nil || mpv.length < (NSUInteger)(3 * Rate * 4)) {
    printf("compare failed: reader %s, mpv bytes %lu\n", reader ? "open" : "nil", (unsigned long)mpv.length);
    return 1;
  }
  int64_t at = llround(atof(argv[5]) * Rate) + Rate;
  NSData *mine = readAt(reader, at - maxLag, window + 2 * maxLag);
  if (mine == nil) {
    printf("compare failed: read returned nil\n");
    return 1;
  }
  int lag;
  double corr;
  bestLag((const int16_t *)mpv.bytes + 2 * Rate, mine.bytes, window, maxLag, &lag, &corr);
  printf("compare lag=%d corr=%.5f\n", lag, corr);
  return 0;
}

static int checkSeeks(const char **argv) {
  NSString *path = @(argv[2]);
  NSInteger stream = atoi(argv[3]);
  FFmpegPCMStreamReader *reader = [[FFmpegPCMStreamReader alloc] initWithSource:path audioStreamIndex:stream
                                                                    mediaOrigin:nil cancellationCheck:nil];
  if (reader == nil) {
    printf("open failed\n");
    return 1;
  }
  const int64_t seconds = 40;
  NSMutableData *sequential = [NSMutableData data];
  for (int64_t frame = 0; frame < seconds * Rate; frame += Rate / 4) {
    NSData *chunk = readAt(reader, frame, Rate / 4);
    if (chunk.length != (NSUInteger)Rate) {
      printf("sequential read failed at %lld\n", frame);
      return 1;
    }
    [sequential appendData:chunk];
  }
  const int16_t *reference = sequential.bytes;
  const int maxLag = Rate / 20;
  void (^check)(const char *, double, NSData *) = ^(const char *label, double offset, NSData *data) {
    int64_t at = llround(offset * Rate);
    if (data.length != (NSUInteger)(Rate / 2 + 2 * maxLag) * 4) {
      printf("%s %.2f lag=nil corr=0\n", label, offset);
      return;
    }
    int lag;
    double corr;
    bestLag(reference + 2 * at, data.bytes, Rate / 2, maxLag, &lag, &corr);
    printf("%s %.2f lag=%d corr=%.5f\n", label, offset, lag, corr);
  };
  NSInteger span = Rate / 2 + 2 * maxLag;
  const double offsets[] = {7.3, 31.05, 2.5, 19.0, 19.25, 33.333};
  for (size_t index = 0; index < sizeof(offsets) / sizeof(offsets[0]); index++) {
    // Reading far away first makes the next read seek.
    readAt(reader, (seconds + 10) * Rate, 1024);
    check("seek", offsets[index], readAt(reader, llround(offsets[index] * Rate) - maxLag, span));
  }
  readAt(reader, 10 * Rate, Rate / 4);
  check("skip", 11.0, readAt(reader, 11 * Rate - maxLag, span));
  check("reread", 3.0, readAt(reader, 3 * Rate - maxLag, span));

  if (reader.duration > 0) {
    int64_t end = llround(reader.duration * Rate);
    NSData *tail = readAt(reader, end - Rate, 2 * Rate);
    long loud = 0;
    const int16_t *samples = tail.bytes;
    for (int64_t i = Rate + Rate / 10; tail && i < 2 * Rate; i++) loud += samples[2 * i] != 0 || samples[2 * i + 1] != 0;
    printf("end %s nonzero=%ld\n", tail ? "ok" : "nil", loud);
  }
  printf("oversize %s\n", readAt(reader, 0, 10 * Rate + 1) == nil ? "rejected" : "accepted");
  printf("negative %s\n", readAt(reader, -1, 16) == nil ? "rejected" : "accepted");
  NSData *cancelled = [reader readFramesAt:30 * Rate count:Rate cancellationCheck:^BOOL { return YES; }];
  printf("cancelled %s failed=%d\n", cancelled == nil ? "nil" : "data", reader.failed);
  printf("after-failure %s\n", readAt(reader, 0, 16) == nil ? "nil" : "data");
  FFmpegPCMStreamReader *video = [[FFmpegPCMStreamReader alloc] initWithSource:path audioStreamIndex:0
                                                                  mediaOrigin:nil cancellationCheck:nil];
  printf("video-stream %s\n", video == nil ? "rejected" : "accepted");
  return 0;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc == 7 && strcmp(argv[1], "compare") == 0) return compareWithMPV(argv);
    if (argc == 4 && strcmp(argv[1], "seeks") == 0) return checkSeeks(argv);
    fprintf(stderr, "usage: compare <media> <ffIndex> <origin|nil> <start> <mpv.raw> | seeks <media> <ffIndex>\n");
    return 2;
  }
}
