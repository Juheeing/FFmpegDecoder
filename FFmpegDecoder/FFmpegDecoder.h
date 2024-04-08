#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "libavformat/avformat.h"
#import "libavutil/imgutils.h"
#import "libavcodec/avcodec.h"
#import "libswscale/swscale.h"

@protocol DecoderDelegate <NSObject>

- (void) receivedDecodedImage:(UIImage *)image;
- (void) receivedCurrentTime:(int64_t)seconds;
- (void) receivedTotalDuration:(int64_t)seconds;

@end

@interface FFmpegDecoder : NSObject

@property (nonatomic, weak) id<DecoderDelegate> delegate;
@property (nonatomic, strong)AVAudioEngine *engine;
@property (nonatomic, strong)AVAudioPlayerNode *player;

- (void) startStreaming:(NSString *)url;
- (void) stopDecoding;
- (void) playPauseDecoding;
- (BOOL) progressDecoding;

@end
