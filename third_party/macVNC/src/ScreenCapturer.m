#import "ScreenCapturer.h"

static void CapLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void CapLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss.SSS";
    fprintf(stderr, "%s [capture] %s\n", [[df stringFromDate:[NSDate date]] UTF8String], [msg UTF8String]);
    fflush(stderr);
}

static BOOL IsPermissionError(NSError *error) {
    return [error.domain isEqualToString:SCStreamErrorDomain] && error.code == SCStreamErrorUserDeclined;
}

@interface ScreenCapturer ()

@property (nonatomic, assign) CGDirectDisplayID displayID;
@property (nonatomic, assign) size_t width;
@property (nonatomic, assign) size_t height;

@property (nonatomic, strong, nullable) SCStream *stream;
@property (nonatomic, strong, nullable) SCContentFilter *filter;
@property (nonatomic, strong, nullable) SCStreamConfiguration *config;

/* All state changes happen on this serial queue. */
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong, nullable) dispatch_source_t snapshotTimer;
@property (nonatomic, assign) BOOL busy;            /* a snapshot or content refresh is in flight */
@property (nonatomic, assign) BOOL contentStale;    /* re-query SCShareableContent before next snapshot */
@property (nonatomic, assign) unsigned long errorCount;
@property (nonatomic, assign) unsigned long frameCount;

@property (nonatomic, copy, nonnull) void (^frameHandler)(CMSampleBufferRef sampleBuffer);
@property (nonatomic, copy, nonnull) void (^errorHandler)(NSError *error);

@end


@implementation ScreenCapturer

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                          width:(size_t)width
                         height:(size_t)height
                   frameHandler:(void (^)(CMSampleBufferRef))frameHandler
                   errorHandler:(void (^)(NSError *))errorHandler {
    if (self = [super init]) {
        _displayID = displayID;
        _width = width;
        _height = height;
        _snapshotFPS = 15;
        _queue = dispatch_queue_create("macvnc.capture", DISPATCH_QUEUE_SERIAL);
        _frameHandler = [frameHandler copy];
        _errorHandler = [errorHandler copy];
    }
    return self;
}

/*
  Look up the display and build filter + config.
  The output size is pinned to the size the server was started with,
  so a display change can never overflow the framebuffer.
*/
- (void)refreshContent:(void (^)(BOOL ok))completion {
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(self.queue, ^{
            if (error) {
                if (IsPermissionError(error)) {
                    self.errorHandler(error);
                    return;
                }
                [self logError:@"shareable content" error:error];
                completion(NO);
                return;
            }

            NSMutableArray<NSString *> *seen = [NSMutableArray array];
            for (SCDisplay *d in content.displays)
                [seen addObject:[NSString stringWithFormat:@"%u (%ldx%ld)", d.displayID, (long)d.width, (long)d.height]];
            CapLog(@"displays visible: [%@], want %u", [seen componentsJoinedByString:@", "], self.displayID);

            SCDisplay *display = nil;
            for (SCDisplay *d in content.displays) {
                if (d.displayID == self.displayID) { display = d; break; }
            }
            if (!display && content.displays.count > 0) {
                display = content.displays.firstObject;
                CapLog(@"display %u not listed, using display %u", self.displayID, display.displayID);
            }
            if (!display) {
                [self logError:@"shareable content" error:[NSError errorWithDomain:@"ScreenCapturerErrorDomain" code:1
                    userInfo:@{NSLocalizedDescriptionKey: @"no displays available for capture"}]];
                completion(NO);
                return;
            }

            SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
            config.width = self.width;
            config.height = self.height;
            config.minimumFrameInterval = CMTimeMake(1, 60);
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.showsCursor = YES;

            self.config = config;
            self.filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            self.contentStale = NO;
            completion(YES);
        });
    }];
}

- (void)startCapture {
    dispatch_async(self.queue, ^{
        if (self.snapshotOnly) {
            CapLog(@"snapshot mode forced, %d fps", self.snapshotFPS);
            [self startSnapshots];
            return;
        }
        [self refreshContent:^(BOOL ok) {
            if (ok)
                [self startStream];
            else
                [self startSnapshots];
        }];
    });
}

/* Runs on self.queue. */
- (void)startStream {
    self.stream = [[SCStream alloc] initWithFilter:self.filter configuration:self.config delegate:self];

    NSError *addOutputError = nil;
    [self.stream addStreamOutput:self
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:dispatch_queue_create("macvnc.stream", NULL)
                           error:&addOutputError];
    if (addOutputError) {
        [self streamFailed:addOutputError];
        return;
    }

    [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
        if (startError) {
            dispatch_async(self.queue, ^{ [self streamFailed:startError]; });
        } else {
            CapLog(@"stream started");
        }
    }];
}

/* Runs on self.queue. */
- (void)streamFailed:(NSError *)error {
    if (IsPermissionError(error)) {
        self.errorHandler(error);
        return;
    }
    CapLog(@"stream stopped: %@ (%@ %ld) -> falling back to snapshots at %d fps",
           error.localizedDescription, error.domain, (long)error.code, self.snapshotFPS);
    self.stream = nil;
    self.contentStale = YES;
    [self startSnapshots];
}

/* Runs on self.queue. */
- (void)startSnapshots {
    if (self.snapshotTimer)
        return;

    int fps = self.snapshotFPS > 0 ? self.snapshotFPS : 15;
    uint64_t interval = NSEC_PER_SEC / (uint64_t)fps;

    self.snapshotTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.snapshotTimer, dispatch_time(DISPATCH_TIME_NOW, 0), interval, interval / 10);
    dispatch_source_set_event_handler(self.snapshotTimer, ^{ [self snapshotTick]; });
    dispatch_resume(self.snapshotTimer);
}

/* Runs on self.queue. Skips the tick if the previous one has not finished yet. */
- (void)snapshotTick {
    if (self.busy)
        return;
    self.busy = YES;

    if (!self.filter || self.contentStale) {
        [self refreshContent:^(BOOL ok) { self.busy = NO; }];
        return;
    }

    [SCScreenshotManager captureSampleBufferWithFilter:self.filter
                                         configuration:self.config
                                     completionHandler:^(CMSampleBufferRef sampleBuffer, NSError *error) {
        if (sampleBuffer)
            CFRetain(sampleBuffer);
        dispatch_async(self.queue, ^{
            if (error) {
                if (IsPermissionError(error)) {
                    self.errorHandler(error);
                } else {
                    [self logError:@"snapshot" error:error];
                    self.contentStale = YES;
                }
            } else if (sampleBuffer) {
                if (self.frameCount++ == 0)
                    CapLog(@"first snapshot frame received");
                self.errorCount = 0;
                self.frameHandler(sampleBuffer);
            }
            if (sampleBuffer)
                CFRelease(sampleBuffer);
            self.busy = NO;
        });
    }];
}

/* Log the first error of a streak and then every 100th, so polling does not flood the log. */
- (void)logError:(NSString *)what error:(NSError *)error {
    if (self.errorCount++ % 100 == 0)
        CapLog(@"%@ failed (#%lu): %@ (%@ %ld)", what, self.errorCount,
               error.localizedDescription, error.domain, (long)error.code);
}

- (void)stopCapture {
    dispatch_async(self.queue, ^{
        if (self.snapshotTimer) {
            dispatch_source_cancel(self.snapshotTimer);
            self.snapshotTimer = nil;
        }
        [self.stream stopCaptureWithCompletionHandler:^(NSError * _Nullable stopError) {}];
        self.stream = nil;
    });
}


/*
  SCStreamDelegate methods
*/

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(self.queue, ^{
        if (stream == self.stream)
            [self streamFailed:error];
    });
}


/*
  SCStreamOutput methods
*/

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type == SCStreamOutputTypeScreen) {
        self.frameHandler(sampleBuffer);
    }
}

@end
