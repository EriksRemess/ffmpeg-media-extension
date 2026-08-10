#import <Foundation/Foundation.h>
#import <MediaExtension/MediaExtension.h>
#import <CoreVideo/CoreVideo.h>

#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

static const CMVideoCodecType FMEVideoCodecTypeVP9 = 'FVP9';

static NSError *FMEDecoderError(MEError code, NSString *message) {
    return [NSError errorWithDomain:MediaExtensionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

typedef void (^FMEVideoCompletion)(CVImageBufferRef imageBuffer,
                                   MEDecodeFrameStatus status,
                                   NSError *error);

@interface FMEPendingDecode : NSObject
@property(nonatomic) int64_t pts;
@property(nonatomic) BOOL suppressOutput;
@property(nonatomic, copy) FMEVideoCompletion completion;
@end

@implementation FMEPendingDecode
@end

@interface FMEVideoDecoder : NSObject <MEVideoDecoder> {
    AVCodecContext *_codecContext;
    AVFrame *_frame;
    struct SwsContext *_swsContext;
    OSType _outputPixelFormat;
    NSDictionary<NSString *, id> *_imageBufferAttachments;
}
@property(nonatomic) MEVideoDecoderPixelBufferManager *pixelBufferManager;
@property(nonatomic) NSMutableArray<FMEPendingDecode *> *pendingDecodes;
- (nullable instancetype)initWithCodecID:(enum AVCodecID)codecID
                       formatDescription:(CMVideoFormatDescriptionRef)formatDescription
                      pixelBufferManager:(MEVideoDecoderPixelBufferManager *)pixelBufferManager
                                   error:(NSError **)error;
@end

@implementation FMEVideoDecoder

- (instancetype)initWithCodecID:(enum AVCodecID)codecID
               formatDescription:(CMVideoFormatDescriptionRef)formatDescription
              pixelBufferManager:(MEVideoDecoderPixelBufferManager *)pixelBufferManager
                           error:(NSError **)error {
    if (!(self = [super init])) return nil;

    const AVCodec *codec = avcodec_find_decoder(codecID);
    _codecContext = codec ? avcodec_alloc_context3(codec) : NULL;
    _frame = av_frame_alloc();
    if (!_codecContext || !_frame) {
        if (error) *error = FMEDecoderError(MEErrorAllocationFailure, @"Unable to allocate the FFmpeg decoder.");
        return nil;
    }

    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    _codecContext->width = dimensions.width;
    _codecContext->height = dimensions.height;
    _codecContext->time_base = (AVRational){1, 1000000};
    _codecContext->thread_count = 0;
    // VideoToolbox may wait for a sample's completion before submitting the
    // next sample.  FFmpeg frame threading intentionally buffers the first
    // packet, which deadlocks that call pattern for VP9.  Slice threading
    // retains intra-frame parallelism without adding decode latency.
    _codecContext->thread_type = FF_THREAD_SLICE;

    NSDictionary<NSString *, id> *extensions = (__bridge NSDictionary *)CMFormatDescriptionGetExtensions(formatDescription);
    NSString *primaries = extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries];
    NSString *transfer = extensions[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction];
    NSString *matrix = extensions[(__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix];
    NSNumber *fullRange = extensions[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo];
    if (primaries) {
        _codecContext->color_primaries = (enum AVColorPrimaries)CVColorPrimariesGetIntegerCodePointForString(
            (__bridge CFStringRef)primaries);
    }
    if (transfer) {
        _codecContext->color_trc = (enum AVColorTransferCharacteristic)CVTransferFunctionGetIntegerCodePointForString(
            (__bridge CFStringRef)transfer);
    }
    if (matrix) {
        _codecContext->colorspace = (enum AVColorSpace)CVYCbCrMatrixGetIntegerCodePointForString(
            (__bridge CFStringRef)matrix);
    }
    if (fullRange) {
        _codecContext->color_range = fullRange.boolValue ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
    }

    NSDictionary *atoms = extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms];
    NSData *configuration = extensions[@"lv.apps.ffmpeg.extradata"] ?: atoms[@"vpcC"] ?: atoms[@"av1C"];
    if (configuration.length > 0) {
        _codecContext->extradata = av_mallocz(configuration.length + AV_INPUT_BUFFER_PADDING_SIZE);
        if (!_codecContext->extradata) {
            if (error) *error = FMEDecoderError(MEErrorAllocationFailure, @"Unable to allocate codec configuration data.");
            return nil;
        }
        memcpy(_codecContext->extradata, configuration.bytes, configuration.length);
        _codecContext->extradata_size = (int)configuration.length;
    }

    int result = avcodec_open2(_codecContext, codec, NULL);
    if (result < 0) {
        if (error) *error = FMEDecoderError(MEErrorUnsupportedFeature,
                                            [NSString stringWithFormat:@"FFmpeg could not open the %s decoder.", codec->name]);
        return nil;
    }

    _pixelBufferManager = pixelBufferManager;
    _pendingDecodes = [NSMutableArray array];
    BOOL isHDR = [transfer isEqualToString:(__bridge NSString *)kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ] ||
        [transfer isEqualToString:(__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG];
    _outputPixelFormat = isHDR
        ? (fullRange.boolValue
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        : kCVPixelFormatType_32BGRA;

    NSMutableDictionary<NSString *, id> *attachments = [NSMutableDictionary dictionary];
    NSArray<NSString *> *attachmentKeys = @[
        (__bridge NSString *)kCVImageBufferColorPrimariesKey,
        (__bridge NSString *)kCVImageBufferTransferFunctionKey,
        (__bridge NSString *)kCVImageBufferYCbCrMatrixKey,
        (__bridge NSString *)kCVImageBufferChromaLocationTopFieldKey,
        (__bridge NSString *)kCVImageBufferChromaLocationBottomFieldKey,
        (__bridge NSString *)kCVImageBufferMasteringDisplayColorVolumeKey,
        (__bridge NSString *)kCVImageBufferContentLightLevelInfoKey,
    ];
    for (NSString *key in attachmentKeys) {
        if (extensions[key]) attachments[key] = extensions[key];
    }
    _imageBufferAttachments = attachments.copy;

    pixelBufferManager.pixelBufferAttributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(_outputPixelFormat),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(dimensions.width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(dimensions.height),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    return self;
}

- (void)dealloc {
    NSError *error = FMEDecoderError(MEErrorEndOfStream, @"The decoder was closed before a delayed frame was emitted.");
    for (FMEPendingDecode *pending in _pendingDecodes) pending.completion(NULL, MEDecodeFrameNoStatus, error);
    if (_swsContext) sws_freeContext(_swsContext);
    av_frame_free(&_frame);
    avcodec_free_context(&_codecContext);
}

- (BOOL)isReadyForMoreMediaData {
    return YES;
}

- (BOOL)contentHasInterframeDependencies {
    return YES;
}

- (NSArray<NSNumber *> *)supportedPixelFormatsOrderedByQuality {
    return @[@(_outputPixelFormat)];
}

- (BOOL)canAcceptFormatDescription:(CMFormatDescriptionRef)formatDescription {
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    return dimensions.width == _codecContext->width && dimensions.height == _codecContext->height;
}

- (CVPixelBufferRef)copyPixelBufferForFrame:(AVFrame *)frame error:(NSError **)error {
    CVPixelBufferRef pixelBuffer = [self.pixelBufferManager createPixelBufferAndReturnError:error];
    if (!pixelBuffer) return NULL;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    BOOL isHDR = _outputPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        _outputPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    if (isHDR && CVPixelBufferGetPlaneCount(pixelBuffer) != 2) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CFRelease(pixelBuffer);
        if (error) *error = FMEDecoderError(MEErrorInternalFailure, @"The HDR output pixel buffer is not bi-planar.");
        return NULL;
    }

    uint8_t *destination[4] = {NULL, NULL, NULL, NULL};
    int destinationStrides[4] = {0, 0, 0, 0};
    enum AVPixelFormat destinationFormat;
    if (isHDR) {
        destination[0] = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        destination[1] = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        destinationStrides[0] = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        destinationStrides[1] = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        destinationFormat = AV_PIX_FMT_P010LE;
    } else {
        destination[0] = CVPixelBufferGetBaseAddress(pixelBuffer);
        destinationStrides[0] = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);
        destinationFormat = AV_PIX_FMT_BGRA;
    }
    _swsContext = sws_getCachedContext(_swsContext,
                                       frame->width,
                                       frame->height,
                                       (enum AVPixelFormat)frame->format,
                                       (int)CVPixelBufferGetWidth(pixelBuffer),
                                       (int)CVPixelBufferGetHeight(pixelBuffer),
                                       destinationFormat,
                                       SWS_BILINEAR,
                                       NULL,
                                       NULL,
                                       NULL);
    enum AVColorSpace sourceSpace = frame->colorspace != AVCOL_SPC_UNSPECIFIED
        ? frame->colorspace : _codecContext->colorspace;
    int swsColorspace = SWS_CS_DEFAULT;
    switch (sourceSpace) {
        case AVCOL_SPC_BT709: swsColorspace = SWS_CS_ITU709; break;
        case AVCOL_SPC_SMPTE240M: swsColorspace = SWS_CS_SMPTE240M; break;
        case AVCOL_SPC_BT2020_NCL: swsColorspace = SWS_CS_BT2020; break;
        default: break;
    }
    enum AVColorRange sourceRange = frame->color_range != AVCOL_RANGE_UNSPECIFIED
        ? frame->color_range : _codecContext->color_range;
    if (_swsContext) {
        const int *coefficients = sws_getCoefficients(swsColorspace);
        int sourceIsFullRange = sourceRange == AVCOL_RANGE_JPEG;
        int destinationIsFullRange = isHDR
            ? (_outputPixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
            : 1;
        sws_setColorspaceDetails(_swsContext,
                                 coefficients,
                                 sourceIsFullRange,
                                 coefficients,
                                 destinationIsFullRange,
                                 0,
                                 1 << 16,
                                 1 << 16);
    }
    int rows = _swsContext ? sws_scale(_swsContext,
                                       (const uint8_t *const *)frame->data,
                                       frame->linesize,
                                       0,
                                       frame->height,
                                       destination,
                                       destinationStrides) : 0;
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    if (rows <= 0) {
        CFRelease(pixelBuffer);
        if (error) *error = FMEDecoderError(MEErrorInternalFailure, @"FFmpeg could not convert the decoded video frame.");
        return NULL;
    }
    if (_imageBufferAttachments.count > 0) {
        CVBufferSetAttachments(pixelBuffer,
                               (__bridge CFDictionaryRef)_imageBufferAttachments,
                               kCVAttachmentMode_ShouldPropagate);
    }
    return pixelBuffer;
}

- (void)emitAvailableFrames {
    while (avcodec_receive_frame(_codecContext, _frame) == 0) {
        int64_t framePTS = _frame->best_effort_timestamp;
        NSUInteger pendingIndex = 0;
        if (framePTS != AV_NOPTS_VALUE) {
            NSUInteger match = [_pendingDecodes indexOfObjectPassingTest:^BOOL(FMEPendingDecode *pending, NSUInteger index, BOOL *stop) {
                return pending.pts == framePTS;
            }];
            if (match != NSNotFound) pendingIndex = match;
        }

        if (_pendingDecodes.count == 0) {
            av_frame_unref(_frame);
            continue;
        }
        FMEPendingDecode *pending = _pendingDecodes[pendingIndex];
        [_pendingDecodes removeObjectAtIndex:pendingIndex];

        if (pending.suppressOutput) {
            pending.completion(NULL, MEDecodeFrameFrameDropped, nil);
        } else {
            NSError *pixelError = nil;
            CVPixelBufferRef pixelBuffer = [self copyPixelBufferForFrame:_frame error:&pixelError];
            pending.completion(pixelBuffer, MEDecodeFrameNoStatus, pixelError);
            if (pixelBuffer) CFRelease(pixelBuffer);
        }
        av_frame_unref(_frame);
    }
}

- (void)decodeFrameFromSampleBuffer:(CMSampleBufferRef)sampleBuffer
                            options:(MEDecodeFrameOptions *)options
                  completionHandler:(void (^)(CVImageBufferRef, MEDecodeFrameStatus, NSError *))completionHandler {
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t dataLength = blockBuffer ? CMBlockBufferGetDataLength(blockBuffer) : 0;
    if (dataLength == 0 || dataLength > INT_MAX) {
        completionHandler(NULL, MEDecodeFrameNoStatus,
                          FMEDecoderError(MEErrorInvalidParameter, @"The compressed sample contains no usable data."));
        return;
    }

    AVPacket *packet = av_packet_alloc();
    uint8_t *packetData = av_malloc(dataLength + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!packet || !packetData) {
        av_packet_free(&packet);
        av_free(packetData);
        completionHandler(NULL, MEDecodeFrameNoStatus,
                          FMEDecoderError(MEErrorAllocationFailure, @"Unable to allocate a compressed packet."));
        return;
    }
    memset(packetData + dataLength, 0, AV_INPUT_BUFFER_PADDING_SIZE);
    OSStatus copyStatus = CMBlockBufferCopyDataBytes(blockBuffer, 0, dataLength, packetData);
    if (copyStatus != noErr) {
        av_packet_free(&packet);
        av_free(packetData);
        completionHandler(NULL, MEDecodeFrameNoStatus,
                          FMEDecoderError(MEErrorInvalidParameter, @"Unable to read the compressed sample."));
        return;
    }
    av_packet_from_data(packet, packetData, (int)dataLength);

    CMSampleTimingInfo timing = {0};
    CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);
    CMTime pts = CMTimeConvertScale(timing.presentationTimeStamp, 1000000, kCMTimeRoundingMethod_Default);
    CMTime dts = CMTimeConvertScale(timing.decodeTimeStamp, 1000000, kCMTimeRoundingMethod_Default);
    packet->pts = CMTIME_IS_NUMERIC(pts) ? pts.value : AV_NOPTS_VALUE;
    packet->dts = CMTIME_IS_NUMERIC(dts) ? dts.value : AV_NOPTS_VALUE;

    FMEPendingDecode *pending = [FMEPendingDecode new];
    pending.pts = packet->pts;
    pending.suppressOutput = options.doNotOutputFrame;
    pending.completion = completionHandler;
    [_pendingDecodes addObject:pending];

    int result = avcodec_send_packet(_codecContext, packet);
    av_packet_free(&packet);
    if (result < 0) {
        [_pendingDecodes removeObject:pending];
        completionHandler(NULL, MEDecodeFrameNoStatus,
                          FMEDecoderError(MEErrorParsingFailure, @"FFmpeg rejected the compressed video packet."));
        return;
    }
    [self emitAvailableFrames];
}

@end

@interface FMEVideoDecoderFactory : NSObject <MEVideoDecoderExtension>
@end

@implementation FMEVideoDecoderFactory

- (id<MEVideoDecoder>)videoDecoderWithCodecType:(CMVideoCodecType)codecType
                         videoFormatDescription:(CMVideoFormatDescriptionRef)videoFormatDescription
                     videoDecoderSpecifications:(NSDictionary<NSString *,id> *)videoDecoderSpecifications
              extensionDecoderPixelBufferManager:(MEVideoDecoderPixelBufferManager *)pixelBufferManager
                                           error:(NSError **)error {
    enum AVCodecID codecID;
    switch (codecType) {
        case FMEVideoCodecTypeVP9: codecID = AV_CODEC_ID_VP9; break;
        case kCMVideoCodecType_AV1: codecID = AV_CODEC_ID_AV1; break;
        case kCMVideoCodecType_MPEG2Video: codecID = AV_CODEC_ID_MPEG2VIDEO; break;
        default:
            if (error) *error = FMEDecoderError(MEErrorUnsupportedFeature, @"This FFmpeg decoder supports VP9, AV1, and MPEG-2 Video only.");
            return nil;
    }
    return [[FMEVideoDecoder alloc] initWithCodecID:codecID
                                  formatDescription:videoFormatDescription
                                 pixelBufferManager:pixelBufferManager
                                              error:error];
}

@end
