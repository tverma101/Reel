#!/usr/bin/env python3
"""Decode real thumbnails and check the production worker relinquishes private image ownership."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "iina/FFmpegController.m").read_text().split("// MARK: - Probing Video", 1)[0] + "\n@end\n"
STUB = '''#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
@interface FFmpegLogger: NSObject
+ (void)debug:(NSString *)message;
+ (void)error:(NSString *)message;
+ (void)warn:(NSString *)message;
@end
@implementation FFmpegLogger
+ (void)debug:(NSString *)message {}
+ (void)error:(NSString *)message {}
+ (void)warn:(NSString *)message {}
@end
'''
HARNESS = r'''
@interface FFmpegController (ThumbnailTestMethod)
- (void)saveThumbnail:(AVFrame *)frame width:(int)width height:(int)height index:(int)index
             realTime:(int)second forFile:(NSString *)file;
@end
@interface CancellableThumbnailController: FFmpegController
@property BOOL cancelAfterImage;
@property BOOL didCancel;
@end
@implementation CancellableThumbnailController
- (void)saveThumbnail:(AVFrame *)frame width:(int)width height:(int)height index:(int)index
             realTime:(int)second forFile:(NSString *)file {
  [super saveThumbnail:frame width:width height:height index:index realTime:second forFile:file];
  if (self.cancelAfterImage) {
    self.didCancel = YES;
    [[self valueForKey:@"queue"] cancelAllOperations];
  }
}
@end
@interface ThumbnailReceiver: NSObject <FFmpegControllerDelegate>
@property NSArray<FFThumbnail *> *published;
@property BOOL succeeded;
@property BOOL cancelOnPartial;
@property FFmpegController *controller;
@end
@implementation ThumbnailReceiver
- (void)didUpdateThumbnails:(NSArray *)thumbnails forFile:(NSString *)file withProgress:(NSInteger)progress {
  if (self.cancelOnPartial) { [[self.controller valueForKey:@"queue"] cancelAllOperations]; }
}
- (void)didGenerateThumbnails:(NSArray *)thumbnails forFile:(NSString *)file succeeded:(BOOL)succeeded {
  self.published = thumbnails;
  self.succeeded = succeeded;
}
@end
static void check(BOOL condition, NSString *message) {
  if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void empty(FFmpegController *controller) {
  for (NSString *key in @[@"thumbnails", @"thumbnailPartialResult", @"addedTimestamps"]) {
    check([[controller valueForKey:key] count] == 0, @"worker retained thumbnail ownership");
  }
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    CancellableThumbnailController *controller = [CancellableThumbnailController new];
    controller.thumbnailCount = 4;
    ThumbnailReceiver *receiver = [ThumbnailReceiver new];
    receiver.controller = controller;
    controller.delegate = receiver;
    NSString *file = @(argv[1]);
    [controller generateThumbnailForFile:file thumbWidth:80];
    NSOperationQueue *queue = [controller valueForKey:@"queue"];
    [queue waitUntilAllOperationsAreFinished];
    check(receiver.succeeded && receiver.published.count > 0, @"real thumbnails were not published");
    check(receiver.published.firstObject.image != nil, @"published image was released prematurely");
    empty(controller);
    [controller generateThumbnailForFile:@"/nonexistent/reel-check.mkv" thumbWidth:80];
    [queue waitUntilAllOperationsAreFinished];
    check(!receiver.succeeded, @"failed open reported success");
    empty(controller);
    controller.cancelAfterImage = YES;
    [controller generateThumbnailForFile:file thumbWidth:80];
    [queue waitUntilAllOperationsAreFinished];
    check(controller.didCancel, @"cancellation path was not exercised");
    empty(controller);
    puts("PASS: real thumbnail publication, failure and cancellation relinquish worker ownership");
  }
}
'''
with tempfile.TemporaryDirectory(prefix="reel-thumbnail-check-") as folder:
    folder = Path(folder)
    (folder / "Reel-Swift.h").write_text(STUB)
    main, binary, video = folder / "main.m", folder / "check", folder / "fixture.mkv"
    subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=10",
                    "-t", "2", "-c:v", "mpeg4", "-g", "5", "-threads", "1", str(video)], check=True)
    for candidate, negative in [
        (source, False),
        (source.replace("[self->_thumbnails removeAllObjects];", ""), True),
    ]:
        main.write_text(candidate + HARNESS)
        libs = ROOT / "deps/lib"
        compiled = subprocess.run([
            "xcrun", "clang", "-fobjc-arc", "-Wno-incomplete-implementation",
            "-I", str(folder), "-I", str(ROOT / "iina"), "-I", str(ROOT / "deps/include"),
            "-include", "Cocoa/Cocoa.h", str(main), "-framework", "Cocoa", "-framework", "QuartzCore",
            "-L", str(libs), f"-Wl,-rpath,{libs}", "-lavformat.63", "-lavcodec.63", "-lavutil.61",
            "-lswscale.10", "-o", str(binary),
        ], capture_output=True, text=True)
        assert compiled.returncode == 0, compiled.stdout + compiled.stderr
        result = subprocess.run([str(binary), str(video)], capture_output=True, text=True, timeout=30,
                                env=dict(os.environ, DYLD_LIBRARY_PATH=str(libs)))
        if negative:
            assert result.returncode != 0 and "worker retained thumbnail ownership" in result.stderr, result.stdout + result.stderr
        else:
            assert result.returncode == 0, result.stdout + result.stderr
            print(result.stdout.strip())
print("PASS: retained-thumbnail negative control was detected")
