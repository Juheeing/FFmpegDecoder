#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "libswresample/swresample.h"
#import "libavformat/avformat.h"
#import "libavutil/imgutils.h"
#import "libavcodec/avcodec.h"
#import "libavformat/avio.h"
#import "libswscale/swscale.h"

@protocol DecoderDelegate <NSObject>

- (void) startDecoderStreaming;
- (void) receivedDecodedImage:(UIImage *)image;

@end

@interface FFmpegDecoder : NSObject

@property (nonatomic, weak) id<DecoderDelegate> delegate;
@property (nonatomic,strong)AVAudioEngine *engine;
@property (nonatomic,strong)AVAudioPlayerNode *player;

- (void) startStreaming:(NSString *)url;
- (void) stopDecoding;

@end
