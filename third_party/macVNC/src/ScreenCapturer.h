#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/*
  Captures one display.

  Starts with a continuous SCStream. When the stream fails (e.g. the session is
  switched to the background by Fast User Switching), it does not give up but
  falls back to polling single frames via SCScreenshotManager, which keeps
  working for a background session.

  errorHandler is only called for errors that cannot be recovered from
  (screen recording permission declined).
*/
@interface ScreenCapturer : NSObject <SCStreamDelegate, SCStreamOutput>

/* Skip the SCStream and poll snapshots from the start. Set before startCapture. */
@property (nonatomic, assign) BOOL snapshotOnly;
/* Snapshot polling rate. Default 15. Set before startCapture. */
@property (nonatomic, assign) int snapshotFPS;

- (instancetype)initWithDisplay:(CGDirectDisplayID)displayID
                          width:(size_t)width
                         height:(size_t)height
                   frameHandler:(nonnull void (^)(CMSampleBufferRef sampleBuffer))frameHandler
                   errorHandler:(nonnull void (^)(NSError *error))errorHandler;

- (void)startCapture;
- (void)stopCapture;

@end

NS_ASSUME_NONNULL_END
