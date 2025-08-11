#import "FFmpegDecoder.h"

static void ffmpeg_log_callback(void* ptr, int level, const char* fmt, va_list vl)
{
    if (level > av_log_get_level()) return;

    char log_buf[1024];
    vsnprintf(log_buf, sizeof(log_buf), fmt, vl);
    
    NSString *logMessage = [NSString stringWithUTF8String:log_buf];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"%@", logMessage);
    });
}

@implementation FFmpegDecoder {
    struct SwsContext* swsCtx;
    AVFormatContext *pFormatContext;
    AVCodecContext *pVCtx, *pACtx;
    AVCodecParameters *pVPara, *pAPara;
    AVCodec *pVCodec, *pACodec;
    AVStream* pVStream, * pAStream;
    AVPacket packet;
    AVFrame *vFrame, *aFrame;
    CGSize outputFrameSize;
    dispatch_queue_t mDecodingQueue;
    uint8_t *dst_data[4];
    int dst_linesize[4];
    int vidx, aidx;
    BOOL decodingStopped;
    BOOL isPaused, isPlaying, isSeeking;
    double seekTarget;
    NSCondition *pauseCondition;
    dispatch_source_t keepAliveTimer;
    int64_t lastRescaledPTS;      // 이전 프레임 pts (rescaled)
    int64_t ptsOffset;           // 누적 offset
    BOOL hasPendingSeek;         // seek 직후 첫 프레임에서 보정할 플래그
    double pendingSeekSeconds;   // 사용자가 요청한 seek 시간
}

+ (instancetype)sharedInstance {
    static FFmpegDecoder *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[FFmpegDecoder alloc] init];
    });
    return sharedInstance;
}

- (id) init {
    if (self = [super init]) {
        mDecodingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        pauseCondition = [[NSCondition alloc] init];
        decodingStopped = NO;
        isPaused = NO;
        isSeeking = NO;
        isPlaying = YES;
        lastRescaledPTS = -1;
        ptsOffset = 0;
        hasPendingSeek = NO;
        pendingSeekSeconds = 0;
    }
    return self;
}

- (void) dealloc {
    [self stopDecoding];
    [self clear];
    mDecodingQueue = nil;
    pauseCondition = nil;
}

- (void) clear {
    if (vFrame) { av_frame_free(&vFrame); av_frame_unref(vFrame); vFrame = NULL; }
    if (aFrame) { av_frame_free(&aFrame); av_frame_unref(aFrame); aFrame = NULL; }
    if (pVCtx) { avcodec_close(pVCtx); avcodec_free_context(&pVCtx); pVCtx = NULL; }
    if (pACtx) { avcodec_close(pACtx); avcodec_free_context(&pACtx); pACtx = NULL; }
    if (pFormatContext) { avformat_close_input(&pFormatContext); pFormatContext = NULL; }
    if (swsCtx) { sws_freeContext(swsCtx); swsCtx = NULL; }
    if (dst_data) { av_freep(&dst_data[0]); dst_data[0] = NULL; }
    if ([self.engine isRunning]) { [self.engine stop]; }
    if ([self.player isPlaying]) { [self.player stop]; }
}

- (void)startStreaming:(NSString *)url {
    decodingStopped = NO;
    dispatch_async(mDecodingQueue, ^{
        [self openFile: url];
    });
}

- (void)stopDecoding {
    NSLog(@"FFmpeg## stopDecoding");
    [self->pauseCondition lock];
    self->decodingStopped = YES;
    [self->pauseCondition signal];
    [self->pauseCondition unlock];
}

- (BOOL)isPlaying {
    return !self->isPaused;
}

- (void)pause {
    dispatch_async(mDecodingQueue, ^{
        [self->pauseCondition lock];
        self->isPaused = YES;
        [self->pauseCondition unlock];
    });
}

- (void)resume {
    dispatch_async(mDecodingQueue, ^{
        [self->pauseCondition lock];
        self->isPaused = NO;
        [self->pauseCondition signal];
        [self->pauseCondition unlock];
    });
}

- (void)seek:(double)seconds {
    dispatch_async(mDecodingQueue, ^{
        NSLog(@"FFmpeg## isSeeking");
        [self->pauseCondition lock];
        self->seekTarget = seconds;
        self->isSeeking = YES;
        [self->pauseCondition signal];
        [self->pauseCondition unlock];
    });
}

- (void) openFile:(NSString *)url {
    NSLog(@"FFmpeg## openFile: %@", url);
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->_delegate receivedState:0];
    });
    av_log_set_level(AV_LOG_DEBUG);
    av_log_set_callback(ffmpeg_log_callback);
    avformat_network_init();
    pFormatContext = avformat_alloc_context();
    
    AVDictionary *opts = 0;
    int ret = 0;
    av_dict_set(&opts, "rtsp_transport", "tcp", 0);

    //미디어 파일 열기
    //파일의 헤더로 부터 파일 포맷에 대한 정보를 읽어낸 뒤 첫번째 인자 (AVFormatContext) 에 저장.
    //그 뒤의 인자들은 각각 Input Source (스트리밍 URL이나 파일경로), Input Format, demuxer의 추가옵션.
    ret = avformat_open_input(&pFormatContext, [url UTF8String], NULL, &opts);
    
    if (ret != 0) {
        NSLog(@"FFmpeg## File Open Failed");
        [self stopDecoding];
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self->_delegate receivedState:7];
        });
        return;
    }
    
    ret = avformat_find_stream_info(pFormatContext, NULL);
    
    if (ret < 0 ) {
        NSLog(@"FFmpeg## Fail to get Stream Info");
        [self stopDecoding];
        return;
    }
    
    [self openCodec];
}

- (void) openCodec {
    vidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    aidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_AUDIO, -1, vidx, NULL, 0);
    
    // 비디오 코덱 오픈
    if (vidx >= 0) {
       pVStream = pFormatContext->streams[vidx];
       pVPara = pVStream->codecpar;
       pVCodec = (AVCodec*) avcodec_find_decoder(pVPara->codec_id);
       pVCtx = avcodec_alloc_context3(pVCodec);
       avcodec_parameters_to_context(pVCtx, pVPara);
       avcodec_open2(pVCtx, pVCodec, NULL);
       NSLog(@"FFmpeg## 비디오 코덱 : %d, %s(%s)\n", pVCodec->id, pVCodec->name, pVCodec->long_name);
    }
    // 오디오 코덱 오픈
    if (aidx >= 0) {
       pAStream = pFormatContext->streams[aidx];
       pAPara = pAStream->codecpar;
       pACodec = (AVCodec*) avcodec_find_decoder(pAPara->codec_id);
       pACtx = avcodec_alloc_context3(pACodec);
       avcodec_parameters_to_context(pACtx, pAPara);
       avcodec_open2(pACtx, pACodec, NULL);
       NSLog(@"FFmpeg## 오디오 코덱 : %d, %s(%s)\n", pACodec->id, pACodec->name, pACodec->long_name);
    }

    if (pVCodec == NULL) {
        NSLog(@"FFmpeg## No Video Decoder");
    }
    
    if (pACodec == NULL) {
        NSLog(@"FFmpeg## No Audio Decoder");
    }

    //avcodec_open2 : 디코더 정보를 찾을 수 있다면 AVContext에 그 정보를 넘겨줘서 Decoder를 초기화 함
    if (pVCodec && avcodec_open2(pVCtx, pVCodec, NULL) < 0) {
        NSLog(@"FFmpeg## Fail to Initialize Video Decoder");
    }
    
    if (pACodec && avcodec_open2(pACtx, pACodec, NULL) < 0) {
        NSLog(@"FFmpeg## Fail to Initialize Audio Decoder");
    }
    [self decoding];
}

//파일로부터 인코딩 된 비디오, 오디오 데이터를 읽어서 packet에 저장하는 함수
- (void) decoding {
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->_delegate receivedState:1];
    });
    vFrame = av_frame_alloc();
    aFrame = av_frame_alloc();
    packet = *av_packet_alloc();
    
    outputFrameSize = CGSizeMake(self->pVCtx->width, self->pVCtx->height);
    NSLog(@"FFmpeg## Video Resolution: %.0f x %.0f", outputFrameSize.width, outputFrameSize.height);
        
    while (!self->decodingStopped && pFormatContext != NULL) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self->_delegate receivedState:2];
        });
        while (!self->decodingStopped && [self readFrame:&packet] >= 0) {
            [self->_delegate receivedVideoSize:outputFrameSize];
            [self->pauseCondition lock];
            while (!self->decodingStopped && self->isPaused) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self->_delegate receivedState:5];
                });
                [self readPause];
                if (_player.isPlaying) {
                    [_player pause];
                }
                if (self->isSeeking) {
                    NSLog(@"FFmpeg## readSeek");
                    self->isSeeking = NO;
                    [self readSeek:seekTarget];
                }
                [self->pauseCondition wait];
            }
            [self->pauseCondition unlock];
            
            if (!self->isPlaying) {
                [self readPlay];
            }
            if (packet.stream_index == vidx) {
                if ([self sendPacket:pVCtx packet:&packet] >= 0) {
                    int ret = [self receiveFrame:pVCtx frame:vFrame];
                    if (ret >= 0) {
                        [self getCurrentTime:vFrame stream:pVStream];
                        [self drawImage];
                    }
                }
            }
            if (packet.stream_index == aidx) {
                if ([self sendPacket:pACtx packet:&packet] >= 0) {
                    int ret = [self receiveFrame:pACtx frame:aFrame];
                    if (ret >= 0) {
                        [self drawAudio];
                    }
                }
            }
            av_packet_unref(&packet);
        }
    }
    [self clear];
}

- (int) readFrame:(AVPacket *)packet {

    int ret = -1;
    if (pFormatContext != NULL) {
        @try {
            ret = av_read_frame(pFormatContext, packet);
            
            if (ret == AVERROR_EOF) {
                NSLog(@"FFmpeg## readFrame EOF");
                [self stopDecoding];
                dispatch_sync(dispatch_get_main_queue(), ^{
                    [self->_delegate receivedState:6];
                });
            }
        } @catch (NSException *exception) {
            NSLog(@"FFmpeg## av_read_frame error: %@", exception);
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_delegate receivedState:7];
            });
        }
    }
    return ret;
}

- (int) sendPacket:(AVCodecContext *)ctx packet:(AVPacket *)packet {
    
    int ret = -1;
    if(ctx != NULL) {
        @try {
            ret = avcodec_send_packet(ctx, packet);
        } @catch (NSException *exception) {
            NSLog(@"FFmpeg## avcodec_send_packet error");
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_delegate receivedState:7];
            });
        }
    }
    return ret;
}

- (int) receiveFrame:(AVCodecContext *)ctx frame:(AVFrame *)frame {
    
    int ret = -1;
    if (ctx != NULL) {
        @try {
            ret = avcodec_receive_frame(ctx, frame);
        } @catch (NSException *exception) {
            NSLog(@"FFmpeg## avcodec_receive_frame error");
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_delegate receivedState:7];
            });
        }
    }
    return ret;
}

- (int) readPlay {
    
    int ret = -1;
    
    @try {
        isPlaying = YES;
        ret = av_read_play(pFormatContext);
        NSLog(@"FFmpeg## av_read_play: %d", ret);
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self->_delegate receivedState:4];
        });
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_read_play error %@", exception);
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self->_delegate receivedState:7];
        });
    }
    
    return ret;
}

- (int) readPause {
    
    int ret = -1;
    
    @try {
        isPlaying = NO;
        ret = av_read_pause(pFormatContext);
        NSLog(@"FFmpeg## av_read_pause: %d", ret);
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_read_pause error %@", exception);
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self->_delegate receivedState:7];
        });
    }
    
    return ret;
}

- (int)readSeek:(double)seconds {
    int ret = -1;

    @try {
        if (seconds < 0 || !pFormatContext) {
            NSLog(@"FFmpeg## Invalid seek time or context is NULL");
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_delegate receivedState:7];
            });
            return -1;
        }

        lastRescaledPTS = -1;
        ptsOffset = 0;
        hasPendingSeek = YES;
        pendingSeekSeconds = seconds;
        
        int64_t timestamp = (int64_t)(seconds * AV_TIME_BASE);

        // 디코더 상태 초기화
        avcodec_flush_buffers(pVCtx);
        avcodec_flush_buffers(pACtx);

        // seek 수행
        ret = av_seek_frame(pFormatContext, -1, timestamp, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY);

        NSLog(@"FFmpeg## av_seek_frame to %.2f sec (ts: %lld): %d", seconds, timestamp, ret);

        if (ret < 0) {
            NSLog(@"FFmpeg## Seek failed");
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_delegate receivedState:7];
            });
            hasPendingSeek = NO;
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_delegate receivedSeekingState:YES];
            });
        }
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_seek_frame exception: %@", exception);
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self->_delegate receivedState:7];
        });
        ret = -1;
        hasPendingSeek = NO;
    }

    return ret;
}

- (void)getCurrentTime:(AVFrame *)frame stream:(AVStream *)stream {
    int64_t currentTime = 0;
    int64_t totalDuration = pFormatContext->duration / AV_TIME_BASE;

    int64_t raw_pts = (frame->pts != AV_NOPTS_VALUE) ? frame->pts : frame->best_effort_timestamp;
    if (raw_pts == AV_NOPTS_VALUE) {
        currentTime = (lastRescaledPTS != -1) ? (lastRescaledPTS + ptsOffset) : 0;
    } else {
        int64_t rescaled_pts = av_rescale_q(raw_pts, stream->time_base, (AVRational){1, 1});

        if (hasPendingSeek) {
            // seek 직후 첫 프레임: 요청한 초에 맞추기 위한 offset 계산
            ptsOffset = (int64_t)pendingSeekSeconds - rescaled_pts;
            lastRescaledPTS = rescaled_pts;
            hasPendingSeek = NO;
        } else {
            // 일반적인 discontinuity 처리
            if (lastRescaledPTS != -1 && rescaled_pts < lastRescaledPTS) {
                ptsOffset += lastRescaledPTS;
            }
            lastRescaledPTS = rescaled_pts;
        }

        currentTime = rescaled_pts + ptsOffset;
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->_delegate receivedCurrentTime:currentTime duration:totalDuration];
    });
}

- (void) drawImage {
    if (swsCtx == NULL) {
        static int sws_flags =  SWS_FAST_BILINEAR;
        swsCtx = sws_getContext(pVCtx->width, pVCtx->height, pVCtx->pix_fmt, outputFrameSize.width, outputFrameSize.height, AV_PIX_FMT_RGB24, sws_flags, NULL, NULL, NULL);
        av_image_alloc(dst_data, dst_linesize, pVCtx->width, pVCtx->height, AV_PIX_FMT_RGB24, 1);
    }
    sws_scale(swsCtx, (uint8_t const * const *)vFrame->data, vFrame->linesize, 0, pVCtx->height, dst_data, dst_linesize);
    
    if (_delegate) {
       UIImage *image = [self convertToUIImageFromYUV:dst_data linesize:dst_linesize[0] width:vFrame->width height:vFrame->height];
       dispatch_sync(dispatch_get_main_queue(), ^{
           if (image!= nil && (image.CGImage != nil || image.CIImage != nil)) {
               //[self->_delegate receivedDecodedImage:[UIImage imageWithData:UIImagePNGRepresentation(image)]]; // png형식으로 압축 후 전달하기 때문에 row memory, high cpu
               //[self->_delegate receivedDecodedImage:image]; // 압축 없이 원본을 전달하기 때문에 row cpu, high memory
               [self->_delegate receivedDecodedImage:[UIImage imageWithData:UIImageJPEGRepresentation(image, 0.5)]];
           } else {
               [self->_delegate receivedDecodedImage:nil];
           }
       });
   }
}

- (void) drawAudio {
    AVAudioChannelLayout *channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Stereo];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                             sampleRate:aFrame->sample_rate
                                                           interleaved:NO
                                                         channelLayout:channelLayout];
    
    if (![self.player isPlaying]) {
        self.engine = [[AVAudioEngine alloc] init];
        self.player = [[AVAudioPlayerNode alloc] init];
        self.player.volume = 0.5;
        [self.engine attachNode:self.player];

        AVAudioMixerNode *mainMixer = [self.engine mainMixerNode];
        
        [self.engine connect:self.player to:mainMixer format:format];
        
        if (!self.engine.isRunning) {
            [self.engine prepare];
            NSError *error;
            BOOL success;
            success = [self.engine startAndReturnError:&error];
            NSAssert(success, @"couldn't start engine, %@", [error localizedDescription]);
        }
        [self.player play];
    }
    
    NSData *data = [self playAudioFrame:aFrame];
    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc]
                                  initWithPCMFormat:format
                                  frameCapacity:(uint32_t)(data.length)
                                  /format.streamDescription->mBytesPerFrame];

    pcmBuffer.frameLength = pcmBuffer.frameCapacity;

    [data getBytes:*pcmBuffer.floatChannelData length:data.length];

    [self.player scheduleBuffer:pcmBuffer completionHandler:nil];
}

- (UIImage *) convertToUIImageFromYUV:(uint8_t **)dstData linesize:(int)linesize width:(int)width height:(int)height{
    
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, dstData[0], linesize * height, kCFAllocatorNull);
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGImageRef cgImage = CGImageCreate((unsigned long)width,
                                       (unsigned long)height,
                                       8,
                                       24,
                                       (size_t)linesize,
                                       colorSpace,
                                       bitmapInfo,
                                       provider,
                                       NULL,
                                       NO,
                                       kCGRenderingIntentDefault);
    
    CGColorSpaceRelease(colorSpace);
    CIImage *ciImage = [CIImage imageWithCGImage:cgImage];
    CIImage *grayscaleCIImage = [self grayscaleFilter:ciImage];
    if (!grayscaleCIImage) {
        grayscaleCIImage = ciImage;
    }
    UIImage *image = [UIImage imageWithCIImage:grayscaleCIImage];
    CGImageRelease(cgImage);
    CGDataProviderRelease(provider);
    CFRelease(data);
    
    return image;
}

- (NSData *)playAudioFrame:(AVFrame *)audioFrame {
    
    int bytesPerSample = av_get_bytes_per_sample(pACtx->sample_fmt);
    int channels = pACtx->ch_layout.nb_channels; // 최신 FFmpeg (5.x 이상)에서는 ch_layout 사용
    int dataSize = bytesPerSample * channels * audioFrame->nb_samples;

    NSData *audioData = [NSData dataWithBytes:audioFrame->data[0] length:dataSize];
    return audioData;
}

- (CIImage *)grayscaleFilter:(CIImage *)input {
    Filter *filter = [[Filter alloc] init];
    return [filter outputImageWithInput:input];
}

@end
