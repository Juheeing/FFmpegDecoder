#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "libavformat/avformat.h"
#import "libavutil/imgutils.h"
#import "libavcodec/avcodec.h"
#import "libswscale/swscale.h"
#import <Metal/Metal.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>

@protocol DecoderDelegate <NSObject>

- (void)receivedDecodedCIImage:(CIImage *)ciImage context:(CIContext *)ciContext size:(CGSize)size;
- (void) receivedCurrentTime:(int64_t)currentTime duration:(int64_t)duration;
- (void) receivedState:(int64_t)state; // 0: initialized, 1: preparing, 2: readyToPlay, 3: buffering, 4: bufferFinished, 5: paused, 6: playedToTheEnd, 7: error, 8: stop
- (void) receivedSeekingState:(BOOL)success;
- (void) receivedVideoSize:(CGSize)videoSize;

@end

@interface FFmpegDecoder : NSObject
+ (instancetype)sharedInstance;

@property (nonatomic, weak) id<DecoderDelegate> delegate;
@property (nonatomic, strong)AVAudioEngine *engine;
@property (nonatomic, strong)AVAudioPlayerNode *player;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) CIFilter  *ciColorFilter;

- (void) startStreaming:(NSString *)url;
- (void) stopDecoding;
- (void) pause;
- (void) resume;
- (void) seek:(double)seconds;
- (void) setBrightness:(double)bright contrast:(double)contrast;
- (BOOL) isPlaying;

@end
