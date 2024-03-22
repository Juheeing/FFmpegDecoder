#import "FFmpegDecoder.h"

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
}

- (id) init {
    if (self = [super init]) {
        mDecodingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        self->decodingStopped = NO;
    }
    return self;
}

- (void) dealloc {
    [self stopDecoding];
    [self clear];
    mDecodingQueue = nil;
}

- (void) clear {
    av_packet_unref(&packet);
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
    self->decodingStopped = NO;
    dispatch_async(mDecodingQueue, ^{
        [self openFile: url];
    });
}

- (void)stopDecoding {
    self->decodingStopped = YES;
}

- (void) openFile:(NSString *)url {
    NSLog(@"juhee## url: %@", url);
    
    pFormatContext = avformat_alloc_context();
    vFrame = av_frame_alloc();
    aFrame = av_frame_alloc();
    
    if (!vFrame || !aFrame) {
        NSLog(@"juhee## Failed to allocate frames");
        [self stopDecoding];
        return;
    }
    
    AVDictionary *opts = 0;
    int ret = 0;
    /*ret = av_dict_set(&opts, "rtsp_transport", "tcp", 0);
    ret = av_dict_set(&opts, "buffer_size", "1024000", 0);
    ret = av_dict_set(&opts, "max_delay", "500000", 0);
    ret = av_dict_set(&opts, "max_analyze_duration", "5000000", 0);*/

    //미디어 파일 열기
    //파일의 헤더로 부터 파일 포맷에 대한 정보를 읽어낸 뒤 첫번째 인자 (AVFormatContext) 에 저장.
    //그 뒤의 인자들은 각각 Input Source (스트리밍 URL이나 파일경로), Input Format, demuxer의 추가옵션.
    ret = avformat_open_input(&pFormatContext, [url UTF8String], NULL, &opts);
    
    if (ret != 0) {
        NSLog(@"juhee## File Open Failed");
        [self stopDecoding];
        return;
    }
    
    ret = avformat_find_stream_info(pFormatContext, NULL);
    
    if (ret < 0 ) {
        NSLog(@"juhee## Fail to get Stream Info");
        [self stopDecoding];
        return;
    }
    
    NSLog(@"juhee## 시간 = %lld초\n", pFormatContext->duration / AV_TIME_BASE);
    
    [self openCodec];
}

- (void) openCodec {
    vidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    aidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_AUDIO, -1, vidx, NULL, 0);
    
    // 비디오 코덱 오픈
    if (vidx >= 0) {
       pVStream = pFormatContext->streams[vidx];
       pVPara = pVStream->codecpar;
       pVCodec = avcodec_find_decoder(pVPara->codec_id);
       pVCtx = avcodec_alloc_context3(pVCodec);
       avcodec_parameters_to_context(pVCtx, pVPara);
       avcodec_open2(pVCtx, pVCodec, NULL);
       NSLog(@"juhee## 비디오 코덱 : %d, %s(%s)\n", pVCodec->id, pVCodec->name, pVCodec->long_name);
    }
    // 오디오 코덱 오픈
    if (aidx >= 0) {
       pAStream = pFormatContext->streams[aidx];
       pAPara = pAStream->codecpar;
       pACodec = avcodec_find_decoder(pAPara->codec_id);
       pACtx = avcodec_alloc_context3(pACodec);
       avcodec_parameters_to_context(pACtx, pAPara);
       avcodec_open2(pACtx, pACodec, NULL);
       NSLog(@"juhee## 오디오 코덱 : %d, %s(%s)\n", pACodec->id, pACodec->name, pACodec->long_name);
    }

    if (pVCodec == NULL) {
        NSLog(@"juhee## No Video Decoder");
    }
    
    if (pACodec == NULL) {
        NSLog(@"juhee## No Audio Decoder");
    }

    //avcodec_open2 : 디코더 정보를 찾을 수 있다면 AVContext에 그 정보를 넘겨줘서 Decoder를 초기화 함
    if (pVCodec && avcodec_open2(pVCtx, pVCodec, NULL) < 0) {
        NSLog(@"juhee## Fail to Initialize Video Decoder");
    }
    
    if (pACodec && avcodec_open2(pACtx, pACodec, NULL) < 0) {
        NSLog(@"juhee## Fail to Initialize Audio Decoder");
    }
    [self decodingFrame];
}

//파일로부터 인코딩 된 비디오, 오디오 데이터를 읽어서 packet에 저장하는 함수
- (void) decodingFrame {
    outputFrameSize = CGSizeMake(self->pVCtx->width, self->pVCtx->height);
    NSLog(@"juhee## Video Resolution: %.0f x %.0f", outputFrameSize.width, outputFrameSize.height);
    
    int videoIframe = 0, videoPframe = 0, videoTotalFrame = 0;
        
    int ret = 0;
    
    while (!self->decodingStopped && av_read_frame(pFormatContext, &packet) == 0) {
        if (packet.stream_index == vidx) {  // Decoding Video
            
            ret = avcodec_send_packet(pVCtx, &packet);

            if (ret < 0 && ret != AVERROR_EOF) {
                
                NSLog(@"juhee## Video avcodec_send_packet return [%d][%d]",ret,(ret == AVERROR_EOF) ? 0 : ret);
                
            } else if (ret == 0) {
                ret = avcodec_receive_frame(pVCtx, vFrame);
                
                videoTotalFrame ++;
                
                //count GOP
                if (packet.flags & AV_PKT_FLAG_KEY) { // I frame
                    videoIframe++;
                    NSLog(@"juhee## Number of P frames between I frames: %d", videoPframe);
                    NSLog(@"juhee## Total number of I frames: %d", videoIframe);
                    videoPframe = 0;
                    
                } else { // P frame
                    
                    videoPframe++;
                }
                
                 if (swsCtx == NULL) {
                     static int sws_flags =  SWS_FAST_BILINEAR;
                     swsCtx = sws_getContext(pVCtx->width, pVCtx->height, pVCtx->pix_fmt, outputFrameSize.width, outputFrameSize.height, AV_PIX_FMT_RGB24, sws_flags, NULL, NULL, NULL);
                     
                     ret = av_image_alloc(dst_data, dst_linesize, pVCtx->width, pVCtx->height, AV_PIX_FMT_RGB24, 1);
                     
                 }
                
                 ret = sws_scale(swsCtx, (uint8_t const * const *)vFrame->data, vFrame->linesize, 0, pVCtx->height, dst_data, dst_linesize);
                 
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
                
            } else {
                break;
            }
        } else if (packet.stream_index == aidx) {
            
            ret = avcodec_send_packet(pACtx, &packet);
            
            if (ret < 0 && ret != AVERROR_EOF) {
                
                NSLog(@"juhee## Audio avcodec_send_packet return [%d][%d]",ret,(ret == AVERROR_EOF) ? 0 : ret);
                
            } else if (ret == 0) {
                
                ret = avcodec_receive_frame(pACtx, aFrame);
                AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:aFrame->sample_rate channels:aFrame->channels interleaved:NO];
                
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
                
            } else {
                break;
            }
        }
    }

    NSLog(@"juhee## videoTotalFrame: %d", videoTotalFrame);
    
    av_frame_unref(vFrame);
    av_frame_unref(aFrame);
    //AVPacket의 경우 구조체 내에 data라는 포인터 변수가 있기 때문에 포인터타입으로 선언해서 사용하지 않음
    //따라서 다 사용하고 나서 Release해주어야 할 필요가 있음
    av_packet_unref(&packet);
    
    [self clear];
}


- (UIImage *) convertToUIImageFromYUV:(uint8_t **)dstData linesize:(int)linesize width:(int)width height:(int)height{
    
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, dstData[0], linesize*height, kCFAllocatorNull);
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGImageRef cgImage = CGImageCreate((unsigned long) vFrame->width,(unsigned long) vFrame->height, 8, 24, (size_t) linesize, colorSpace, bitmapInfo, provider, NULL, NO, kCGRenderingIntentDefault);
    
    CGColorSpaceRelease(colorSpace);
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    CGDataProviderRelease(provider);
    CFRelease(data);
    
    return image;
    
}

- (NSData *)playAudioFrame:(AVFrame *)audioFrame {
    
    int dataSize = av_get_bytes_per_sample(pACtx->sample_fmt) * pACtx->channels * audioFrame->nb_samples;
    NSData *audioData = [NSData dataWithBytes:audioFrame->data[0] length:dataSize];
        
    return audioData;
}

@end
