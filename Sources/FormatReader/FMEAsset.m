#import "FMEAsset.h"
#import "FMETrackReader.h"

#import <AudioToolbox/AudioToolbox.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

// Route VP9 through our MediaExtension instead of macOS's reserved vp09
// decoder path, which can reject unsupported VP9 profiles before consulting
// extension decoders.
static const CMVideoCodecType FMEVideoCodecTypeVP9 = 'FVP9';

typedef struct {
    void *source;
    void *lastError;
    int64_t offset;
} FMEIOState;

static void fmeSetIOError(FMEIOState *state, NSError *error) {
    if (state->lastError) CFBridgingRelease(state->lastError);
    state->lastError = error ? (__bridge_retained void *)error : NULL;
}

static NSError *fmeStoredIOError(AVFormatContext *context) {
    FMEIOState *state = context && context->pb ? context->pb->opaque : NULL;
    return state && state->lastError ? (__bridge NSError *)state->lastError : nil;
}

static void fmeDestroyIOContext(AVIOContext **ioPointer) {
    if (!ioPointer || !*ioPointer) return;
    AVIOContext *io = *ioPointer;
    FMEIOState *state = io->opaque;
    if (state) {
        if (state->lastError) CFBridgingRelease(state->lastError);
        if (state->source) CFBridgingRelease(state->source);
        free(state);
        io->opaque = NULL;
    }
    av_freep(&io->buffer);
    avio_context_free(ioPointer);
}

static int fmeRead(void *opaque, uint8_t *buffer, int bufferSize) {
    FMEIOState *state = opaque;
    MEByteSource *source = (__bridge MEByteSource *)state->source;
    size_t bytesRead = 0;
    NSError *error = nil;
    BOOL ok = [source readDataOfLength:(size_t)bufferSize
                            fromOffset:state->offset
                         toDestination:buffer
                             bytesRead:&bytesRead
                                 error:&error];
    if (!ok) {
        fmeSetIOError(state, error ?: FMEError(5, @"The media byte source could not be read."));
        return AVERROR(EIO);
    }
    if (bytesRead == 0) return AVERROR_EOF;
    state->offset += (int64_t)bytesRead;
    return (int)bytesRead;
}

static int64_t fmeSeek(void *opaque, int64_t offset, int whence) {
    FMEIOState *state = opaque;
    MEByteSource *source = (__bridge MEByteSource *)state->source;
    if (whence & AVSEEK_SIZE) return source.fileLength;
    whence &= ~AVSEEK_FORCE;

    int64_t target;
    switch (whence) {
        case SEEK_SET: target = offset; break;
        case SEEK_CUR:
            if (__builtin_add_overflow(state->offset, offset, &target)) return AVERROR(EINVAL);
            break;
        case SEEK_END:
            if (__builtin_add_overflow(source.fileLength, offset, &target)) return AVERROR(EINVAL);
            break;
        default: return AVERROR(EINVAL);
    }
    if (target < 0 || (source.fileLength > 0 && target > source.fileLength)) return AVERROR(EINVAL);
    state->offset = target;
    return target;
}

static AVFormatContext *fmeOpenFormatContext(MEByteSource *source, BOOL loadStreamInfo, NSError **error) {
    const int bufferSize = 128 * 1024;
    uint8_t *buffer = av_malloc(bufferSize);
    FMEIOState *state = calloc(1, sizeof(FMEIOState));
    if (!buffer || !state) {
        av_free(buffer);
        free(state);
        if (error) *error = FMEError(1, @"Unable to allocate the FFmpeg input buffer.");
        return NULL;
    }

    state->source = (__bridge_retained void *)source;
    AVIOContext *io = avio_alloc_context(buffer, bufferSize, 0, state, fmeRead, NULL, fmeSeek);
    AVFormatContext *context = avformat_alloc_context();
    if (!io || !context) {
        if (io) {
            fmeDestroyIOContext(&io);
        } else {
            av_free(buffer);
            CFBridgingRelease(state->source);
            free(state);
        }
        avformat_free_context(context);
        if (error) *error = FMEError(2, @"Unable to create the FFmpeg format context.");
        return NULL;
    }

    context->pb = io;
    context->flags |= AVFMT_FLAG_CUSTOM_IO;
    const AVInputFormat *matroska = av_find_input_format("matroska");
    int result = avformat_open_input(&context, NULL, matroska, NULL);
    if (result >= 0 && loadStreamInfo) result = avformat_find_stream_info(context, NULL);
    if (result < 0) {
        char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(result, detail, sizeof(detail));
        NSError *sourceError = fmeStoredIOError(context);
        if (error) *error = sourceError ?: FMEError(3, [NSString stringWithFormat:@"FFmpeg could not parse %@: %s", source.fileName, detail]);
        AVIOContext *failedIO = context && context->pb ? context->pb : io;
        avformat_close_input(&context);
        fmeDestroyIOContext(&failedIO);
        return NULL;
    }
    return context;
}

static void fmeCloseFormatContext(AVFormatContext **context) {
    if (!context || !*context) return;
    AVIOContext *io = (*context)->pb;
    avformat_close_input(context);
    fmeDestroyIOContext(&io);
}

static NSString *fmeColorPrimaries(enum AVColorPrimaries primaries) {
    switch (primaries) {
        case AVCOL_PRI_BT709:
            return (__bridge NSString *)kCMFormatDescriptionColorPrimaries_ITU_R_709_2;
        case AVCOL_PRI_BT470BG:
            return (__bridge NSString *)kCMFormatDescriptionColorPrimaries_EBU_3213;
        case AVCOL_PRI_SMPTE170M:
        case AVCOL_PRI_SMPTE240M:
            return (__bridge NSString *)kCMFormatDescriptionColorPrimaries_SMPTE_C;
        case AVCOL_PRI_BT2020:
            return (__bridge NSString *)kCMFormatDescriptionColorPrimaries_ITU_R_2020;
        case AVCOL_PRI_SMPTE431:
            return (__bridge NSString *)kCMFormatDescriptionColorPrimaries_DCI_P3;
        case AVCOL_PRI_SMPTE432:
            return (__bridge NSString *)kCMFormatDescriptionColorPrimaries_P3_D65;
        default:
            return nil;
    }
}

static NSString *fmeTransferFunction(enum AVColorTransferCharacteristic transfer) {
    switch (transfer) {
        case AVCOL_TRC_BT709:
        case AVCOL_TRC_SMPTE170M:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_709_2;
        case AVCOL_TRC_SMPTE240M:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_SMPTE_240M_1995;
        case AVCOL_TRC_BT2020_10:
        case AVCOL_TRC_BT2020_12:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_2020;
        case AVCOL_TRC_SMPTE428:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_SMPTE_ST_428_1;
        case AVCOL_TRC_SMPTE2084:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ;
        case AVCOL_TRC_ARIB_STD_B67:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG;
        case AVCOL_TRC_LINEAR:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_Linear;
        case AVCOL_TRC_IEC61966_2_1:
            return (__bridge NSString *)kCMFormatDescriptionTransferFunction_sRGB;
        default:
            return nil;
    }
}

static NSString *fmeYCbCrMatrix(enum AVColorSpace space) {
    switch (space) {
        case AVCOL_SPC_BT709:
            return (__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2;
        case AVCOL_SPC_FCC:
        case AVCOL_SPC_BT470BG:
        case AVCOL_SPC_SMPTE170M:
            return (__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4;
        case AVCOL_SPC_SMPTE240M:
            return (__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995;
        case AVCOL_SPC_BT2020_NCL:
            return (__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_2020;
        default:
            return nil;
    }
}

static NSString *fmeChromaLocation(enum AVChromaLocation location) {
    switch (location) {
        case AVCHROMA_LOC_LEFT:
            return (__bridge NSString *)kCMFormatDescriptionChromaLocation_Left;
        case AVCHROMA_LOC_CENTER:
            return (__bridge NSString *)kCMFormatDescriptionChromaLocation_Center;
        case AVCHROMA_LOC_TOPLEFT:
            return (__bridge NSString *)kCMFormatDescriptionChromaLocation_TopLeft;
        case AVCHROMA_LOC_TOP:
            return (__bridge NSString *)kCMFormatDescriptionChromaLocation_Top;
        case AVCHROMA_LOC_BOTTOMLEFT:
            return (__bridge NSString *)kCMFormatDescriptionChromaLocation_BottomLeft;
        case AVCHROMA_LOC_BOTTOM:
            return (__bridge NSString *)kCMFormatDescriptionChromaLocation_Bottom;
        default:
            return nil;
    }
}

static int64_t fmeScaleRational(AVRational value, int scale) {
    if (value.den <= 0 || value.num < 0) return 0;
    return av_rescale(value.num, scale, value.den);
}

static uint16_t fmeUInt16(int64_t value) {
    return value > UINT16_MAX ? UINT16_MAX : (uint16_t)value;
}

static uint32_t fmeUInt32(int64_t value) {
    return value > UINT32_MAX ? UINT32_MAX : (uint32_t)value;
}

static NSData *fmeMasteringDisplayData(AVCodecParameters *parameters) {
    const AVPacketSideData *sideData = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
    if (!sideData || sideData->size < sizeof(AVMasteringDisplayMetadata)) return nil;
    const AVMasteringDisplayMetadata *metadata = (const AVMasteringDisplayMetadata *)sideData->data;
    if (!metadata->has_primaries || !metadata->has_luminance) return nil;

    uint8_t payload[24] = {0};
    // The mastering-display payload uses the HEVC SEI primary order: G, B, R.
    const int primaryOrder[] = {1, 2, 0};
    for (int index = 0; index < 3; index++) {
        int primary = primaryOrder[index];
        AV_WB16(payload + index * 4,
                fmeUInt16(fmeScaleRational(metadata->display_primaries[primary][0], 50000)));
        AV_WB16(payload + index * 4 + 2,
                fmeUInt16(fmeScaleRational(metadata->display_primaries[primary][1], 50000)));
    }
    AV_WB16(payload + 12, fmeUInt16(fmeScaleRational(metadata->white_point[0], 50000)));
    AV_WB16(payload + 14, fmeUInt16(fmeScaleRational(metadata->white_point[1], 50000)));
    AV_WB32(payload + 16, fmeUInt32(fmeScaleRational(metadata->max_luminance, 10000)));
    AV_WB32(payload + 20, fmeUInt32(fmeScaleRational(metadata->min_luminance, 10000)));
    return [NSData dataWithBytes:payload length:sizeof(payload)];
}

static NSData *fmeContentLightData(AVCodecParameters *parameters) {
    const AVPacketSideData *sideData = av_packet_side_data_get(
        parameters->coded_side_data,
        parameters->nb_coded_side_data,
        AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
    if (!sideData || sideData->size < sizeof(AVContentLightMetadata)) return nil;
    const AVContentLightMetadata *metadata = (const AVContentLightMetadata *)sideData->data;
    uint8_t payload[4] = {0};
    AV_WB16(payload, fmeUInt16(metadata->MaxCLL));
    AV_WB16(payload + 2, fmeUInt16(metadata->MaxFALL));
    return [NSData dataWithBytes:payload length:sizeof(payload)];
}

static NSDictionary *fmeVideoExtensions(AVCodecParameters *parameters,
                                        AVRational streamAspect,
                                        NSString *atomName) {
    NSMutableDictionary *extensions = [NSMutableDictionary dictionary];
    if (parameters->extradata_size > 0) {
        NSData *data = [NSData dataWithBytes:parameters->extradata length:(NSUInteger)parameters->extradata_size];
        extensions[@"lv.apps.ffmpeg.extradata"] = data;
        if (atomName) {
            extensions[(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = @{atomName: data};
        }
    }

    // Matroska commonly stores DisplayWidth/DisplayHeight on AVStream rather
    // than AVCodecParameters. avformat_find_stream_info() resolves that into
    // AVStream.sample_aspect_ratio, so prefer it over the codec-level value.
    AVRational aspect = streamAspect.num > 0 && streamAspect.den > 0
        ? streamAspect : parameters->sample_aspect_ratio;
    if (aspect.num > 0 && aspect.den > 0) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_PixelAspectRatio] = @{
            (__bridge NSString *)kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: @(aspect.num),
            (__bridge NSString *)kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: @(aspect.den),
        };
    }

    NSString *primaries = fmeColorPrimaries(parameters->color_primaries);
    NSString *transfer = fmeTransferFunction(parameters->color_trc);
    NSString *matrix = fmeYCbCrMatrix(parameters->color_space);
    NSString *chromaLocation = fmeChromaLocation(parameters->chroma_location);
    if (primaries) extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries] = primaries;
    if (transfer) extensions[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction] = transfer;
    if (matrix) extensions[(__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix] = matrix;
    if (parameters->color_range != AVCOL_RANGE_UNSPECIFIED) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo] =
            @(parameters->color_range == AVCOL_RANGE_JPEG);
    }
    if (chromaLocation) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ChromaLocationTopField] = chromaLocation;
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ChromaLocationBottomField] = chromaLocation;
    }
    NSData *masteringDisplay = fmeMasteringDisplayData(parameters);
    NSData *contentLight = fmeContentLightData(parameters);
    if (masteringDisplay) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = masteringDisplay;
    }
    if (contentLight) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ContentLightLevelInfo] = contentLight;
    }
    return extensions.count ? extensions : nil;
}

static CMFormatDescriptionRef fmeCreateVideoDescription(AVStream *stream, NSError **error) {
    AVCodecParameters *parameters = stream->codecpar;
    CMVideoCodecType codecType;
    NSString *atomName = nil;
    switch (parameters->codec_id) {
        case AV_CODEC_ID_H264: codecType = kCMVideoCodecType_H264; atomName = @"avcC"; break;
        case AV_CODEC_ID_HEVC: codecType = kCMVideoCodecType_HEVC; atomName = @"hvcC"; break;
        case AV_CODEC_ID_VP9: codecType = FMEVideoCodecTypeVP9; atomName = @"vpcC"; break;
        case AV_CODEC_ID_AV1: codecType = kCMVideoCodecType_AV1; atomName = @"av1C"; break;
        case AV_CODEC_ID_MPEG4: codecType = kCMVideoCodecType_MPEG4Video; atomName = @"esds"; break;
        case AV_CODEC_ID_MPEG2VIDEO: codecType = kCMVideoCodecType_MPEG2Video; break;
        default:
            if (error) *error = FMEError(10, [NSString stringWithFormat:@"Unsupported video codec: %s", avcodec_get_name(parameters->codec_id)]);
            return NULL;
    }

    NSDictionary *extensions = fmeVideoExtensions(parameters, stream->sample_aspect_ratio, atomName);
    CMVideoFormatDescriptionRef description = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                                      codecType,
                                                      parameters->width,
                                                      parameters->height,
                                                      (__bridge CFDictionaryRef)extensions,
                                                      &description);
    if (status != noErr && error) *error = FMEError(status, @"Core Media rejected the video format description.");
    return description;
}

static UInt32 fmeDecodedAudioFramesPerPacket(AVCodecParameters *parameters, NSData *packetData) {
    if (!packetData || packetData.length == 0 || packetData.length > INT_MAX) return 0;
    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    AVCodecContext *context = codec ? avcodec_alloc_context3(codec) : NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    UInt32 framesPerPacket = 0;
    if (context && packet && frame &&
        avcodec_parameters_to_context(context, parameters) >= 0 &&
        avcodec_open2(context, codec, NULL) >= 0 &&
        av_new_packet(packet, (int)packetData.length) >= 0) {
        memcpy(packet->data, packetData.bytes, packetData.length);
        if (avcodec_send_packet(context, packet) >= 0 &&
            avcodec_receive_frame(context, frame) >= 0 && frame->nb_samples > 0) {
            framesPerPacket = (UInt32)frame->nb_samples;
        }
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    return framesPerPacket;
}

static CMFormatDescriptionRef fmeCreateAudioDescription(AVCodecParameters *parameters,
                                                        UInt32 dtsFramesPerPacket,
                                                        NSError **error) {
    AudioFormatID formatID;
    UInt32 framesPerPacket = 0;
    BOOL decodedPCM = NO;
    switch (parameters->codec_id) {
        case AV_CODEC_ID_AAC:
            if (parameters->profile == AV_PROFILE_AAC_HE ||
                parameters->profile == AV_PROFILE_AAC_HE_V2) {
                // Core Audio's compressed HE-AAC path does not reliably
                // recover after Matroska seeks. Decode SBR/PS AAC in FFmpeg
                // and expose the resulting PCM, just like DTS.
                formatID = kAudioFormatLinearPCM;
                framesPerPacket = 1;
                decodedPCM = YES;
            } else {
                formatID = kAudioFormatMPEG4AAC;
                framesPerPacket = 1024;
            }
            break;
        case AV_CODEC_ID_AC3: formatID = kAudioFormatAC3; framesPerPacket = 1536; break;
        case AV_CODEC_ID_EAC3: formatID = kAudioFormatEnhancedAC3; framesPerPacket = 1536; break;
        case AV_CODEC_ID_OPUS: formatID = kAudioFormatOpus; break;
        case AV_CODEC_ID_FLAC: formatID = kAudioFormatFLAC; break;
        case AV_CODEC_ID_MP3: formatID = kAudioFormatMPEGLayer3; framesPerPacket = 1152; break;
        case AV_CODEC_ID_DTS:
            // Core Audio has no public DTS format or decoder.  Decode DTS in
            // the reader and expose native-endian interleaved signed PCM.
            formatID = kAudioFormatLinearPCM;
            framesPerPacket = 1;
            decodedPCM = YES;
            break;
        default:
            if (error) *error = FMEError(11, [NSString stringWithFormat:@"Unsupported audio codec: %s", avcodec_get_name(parameters->codec_id)]);
            return NULL;
    }

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = parameters->sample_rate;
    asbd.mFormatID = formatID;
    asbd.mFramesPerPacket = framesPerPacket;
    // QuickTime's macOS 26 spatial mixer crackles when a format-reader
    // extension supplies decoded 5.1/7.1 DTS as multichannel LPCM.  Stereo
    // LPCM bypasses that renderer while retaining full DTS/DTS-HD decoding.
    asbd.mChannelsPerFrame = decodedPCM ? 2 : parameters->ch_layout.nb_channels;
    if (decodedPCM) {
        if (dtsFramesPerPacket == 0) {
            if (error) *error = FMEError(13, @"FFmpeg could not determine the DTS PCM packet size.");
            return NULL;
        }
        asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger |
                            kAudioFormatFlagIsPacked |
                            kAudioFormatFlagsNativeEndian;
        asbd.mBitsPerChannel = 16;
        asbd.mBytesPerFrame = asbd.mChannelsPerFrame * sizeof(int16_t);
        asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    }

    const void *cookie = !decodedPCM && parameters->extradata_size > 0 ? parameters->extradata : NULL;
    size_t cookieSize = !decodedPCM && parameters->extradata_size > 0
        ? (size_t)parameters->extradata_size : 0;
    AudioChannelLayout layout = {0};
    const AudioChannelLayout *layoutPointer = NULL;
    size_t layoutSize = 0;
    if (decodedPCM) {
        switch (asbd.mChannelsPerFrame) {
            case 1: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono; break;
            case 2: layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo; break;
            case 6: layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A; break;
            // FFmpeg's native 7.1 order is L R C LFE rear-L rear-R side-L
            // side-R, which exactly matches Core Audio's WAVE_7_1 tag.
            case 8: layout.mChannelLayoutTag = kAudioChannelLayoutTag_WAVE_7_1; break;
            default:
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder |
                    asbd.mChannelsPerFrame;
                break;
        }
        layoutPointer = &layout;
        layoutSize = offsetof(AudioChannelLayout, mChannelDescriptions);
    }
    CMAudioFormatDescriptionRef description = NULL;
    OSStatus status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                                      &asbd,
                                                      layoutSize,
                                                      layoutPointer,
                                                      cookieSize,
                                                      cookie,
                                                      NULL,
                                                      &description);
    if (status != noErr && error) *error = FMEError(status, @"Core Media rejected the audio format description.");
    return description;
}


@implementation FMESample
@end

@interface FMEPCMCacheEntry : NSObject
@property(nonatomic) NSData *data;
@property(nonatomic) CMItemCount frameCount;
@end

@implementation FMEPCMCacheEntry
@end


@interface FMEAsset () {
    AVFormatContext *_formatContext;
    AVFormatContext **_readContexts;
    NSInteger *_readIndices;
    AVCodecContext **_audioDecoderContexts;
    SwrContext **_audioResamplers;
    NSInteger *_audioDecodeIndices;
    unsigned _streamCount;
    NSLock *_demuxLock;
    NSLock *_audioDecodeLock;
    NSLock *_indexLock;
    NSMutableDictionary<NSNumber *, NSData *> *_lastPacketDataByStream;
    NSCache<FMESample *, FMEPCMCacheEntry *> *_pcmCache;
    NSMutableDictionary<NSNumber *, FMETrackReader *> *_tracksByStream;
    BOOL _indexReachedEOF;
    NSInteger _primaryVideoStreamIndex;
}
@property(nonatomic, readwrite) MEByteSource *byteSource;
@property(nonatomic, readwrite) CMTime duration;
@property(nonatomic, readwrite) NSArray<FMETrackReader *> *tracks;
@end

@implementation FMEAsset

- (instancetype)initWithByteSource:(MEByteSource *)byteSource error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _byteSource = byteSource;
    _demuxLock = [NSLock new];
    _audioDecodeLock = [NSLock new];
    _indexLock = [NSLock new];
    _lastPacketDataByStream = [NSMutableDictionary dictionary];
    _pcmCache = [NSCache new];
    _pcmCache.countLimit = 4096;
    _pcmCache.totalCostLimit = 16 * 1024 * 1024;
    _tracksByStream = [NSMutableDictionary dictionary];
    _primaryVideoStreamIndex = -1;
    _formatContext = fmeOpenFormatContext(byteSource, YES, error);
    if (!_formatContext) return nil;

    _streamCount = _formatContext->nb_streams;
    _readContexts = calloc(_streamCount, sizeof(*_readContexts));
    _readIndices = malloc(_streamCount * sizeof(*_readIndices));
    _audioDecoderContexts = calloc(_streamCount, sizeof(*_audioDecoderContexts));
    _audioResamplers = calloc(_streamCount, sizeof(*_audioResamplers));
    _audioDecodeIndices = malloc(_streamCount * sizeof(*_audioDecodeIndices));
    if (!_readContexts || !_readIndices || !_audioDecoderContexts ||
        !_audioResamplers || !_audioDecodeIndices) {
        free(_readContexts);
        free(_readIndices);
        free(_audioDecoderContexts);
        free(_audioResamplers);
        free(_audioDecodeIndices);
        _readContexts = NULL;
        _readIndices = NULL;
        _audioDecoderContexts = NULL;
        _audioResamplers = NULL;
        _audioDecodeIndices = NULL;
        _streamCount = 0;
        if (error) *error = FMEError(4, @"Unable to allocate packet reader state.");
        fmeCloseFormatContext(&_formatContext);
        return nil;
    }
    for (unsigned index = 0; index < _streamCount; index++) {
        _readIndices[index] = -1;
        _audioDecodeIndices[index] = -1;
    }

    _duration = _formatContext->duration == AV_NOPTS_VALUE
        ? kCMTimeInvalid
        : CMTimeMake(_formatContext->duration, AV_TIME_BASE);

    NSMutableDictionary<NSNumber *, NSMutableArray<FMESample *> *> *samplesByStream = [NSMutableDictionary dictionary];
    for (unsigned index = 0; index < _formatContext->nb_streams; index++) {
        enum AVMediaType type = _formatContext->streams[index]->codecpar->codec_type;
        if (type == AVMEDIA_TYPE_VIDEO || type == AVMEDIA_TYPE_AUDIO) {
            samplesByStream[@(index)] = [NSMutableArray array];
        }
        if (type == AVMEDIA_TYPE_VIDEO && _primaryVideoStreamIndex < 0) {
            _primaryVideoStreamIndex = (NSInteger)index;
        }
    }

    // Build only a small startup window. A full packet scan makes opening a
    // multi-gigabyte movie proportional to file size and is especially costly
    // over SMB/NFS. The index is extended on demand as cursors advance.
    static const NSUInteger initialPacketLimit = 512;
    NSUInteger indexedPacketCount = 0;
    AVPacket *packet = av_packet_alloc();
    int scanResult = packet ? 0 : AVERROR(ENOMEM);
    while (packet && indexedPacketCount < initialPacketLimit &&
           (scanResult = av_read_frame(_formatContext, packet)) >= 0) {
        NSMutableArray<FMESample *> *samples = samplesByStream[@(packet->stream_index)];
        if (samples) {
            FMESample *sample = [FMESample new];
            sample.streamIndex = packet->stream_index;
            sample.decodeIndex = samples.count;
            sample.pts = packet->pts;
            sample.dts = packet->dts;
            sample.duration = packet->duration;
            sample.filePosition = packet->pos;
            sample.packetSize = packet->size;
            sample.flags = packet->flags;
            sample.packetData = [NSData dataWithBytes:packet->data length:(NSUInteger)packet->size];
            [samples addObject:sample];
        }
        indexedPacketCount++;
        av_packet_unref(packet);
    }
    _indexReachedEOF = scanResult == AVERROR_EOF;
    av_packet_free(&packet);
    if (scanResult < 0 && scanResult != AVERROR_EOF) {
        NSError *sourceError = fmeStoredIOError(_formatContext);
        if (error) {
            if (sourceError) {
                *error = sourceError;
            } else {
                char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
                av_strerror(scanResult, detail, sizeof(detail));
                *error = FMEError(6, [NSString stringWithFormat:@"FFmpeg could not build the initial packet index: %s", detail]);
            }
        }
        return nil;
    }

    NSMutableArray<FMETrackReader *> *tracks = [NSMutableArray array];
    [samplesByStream enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSMutableArray<FMESample *> *samples, BOOL *stop) {
        NSInteger streamIndex = key.integerValue;
        AVStream *stream = self->_formatContext->streams[streamIndex];
        NSError *descriptionError = nil;
        UInt32 decodedAudioFramesPerPacket = 0;
        BOOL decodesAudioToPCM = stream->codecpar->codec_id == AV_CODEC_ID_DTS ||
            (stream->codecpar->codec_id == AV_CODEC_ID_AAC &&
             (stream->codecpar->profile == AV_PROFILE_AAC_HE ||
              stream->codecpar->profile == AV_PROFILE_AAC_HE_V2));
        if (decodesAudioToPCM) {
            decodedAudioFramesPerPacket = fmeDecodedAudioFramesPerPacket(
                stream->codecpar, samples.firstObject.packetData);
        }
        CMFormatDescriptionRef description = stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
            ? fmeCreateVideoDescription(stream, &descriptionError)
            : fmeCreateAudioDescription(stream->codecpar, decodedAudioFramesPerPacket, &descriptionError);
        if (!description) return;

        CMMediaType mediaType = stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO
            ? kCMMediaType_Video : kCMMediaType_Audio;
        METrackInfo *trackInfo = [[METrackInfo alloc] initWithMediaType:mediaType
                                                               trackID:(CMPersistentTrackID)(streamIndex + 1)
                                                    formatDescriptions:@[(__bridge id)description]];
        trackInfo.enabled = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;
        trackInfo.naturalTimescale = stream->time_base.den;

        AVDictionaryEntry *language = av_dict_get(stream->metadata, "language", NULL, 0);
        if (language && language->value) trackInfo.extendedLanguageTag = @(language->value);

        if (mediaType == kCMMediaType_Video) {
            trackInfo.naturalSize = CMVideoFormatDescriptionGetPresentationDimensions(
                (CMVideoFormatDescriptionRef)description, true, true);
            AVRational rate = av_guess_frame_rate(self->_formatContext, stream, NULL);
            trackInfo.nominalFrameRate = rate.den ? (Float32)av_q2d(rate) : 0;
            trackInfo.requiresFrameReordering = stream->codecpar->video_delay > 0;
        }

        FMETrackReader *track = [[FMETrackReader alloc] initWithAsset:self
                                                          streamIndex:streamIndex
                                                            timeScale:stream->time_base.den
                                                     formatDescription:description
                                                             trackInfo:trackInfo
                                                       decodesDTSToPCM:decodesAudioToPCM
                                                decodedPCMFramesPerPacket:decodedAudioFramesPerPacket
                                                               samples:samples];
        [tracks addObject:track];
        self->_tracksByStream[@(streamIndex)] = track;
        CFRelease(description);
    }];
    _tracks = [tracks sortedArrayUsingComparator:^NSComparisonResult(FMETrackReader *a, FMETrackReader *b) {
        return a.streamIndex < b.streamIndex ? NSOrderedAscending : NSOrderedDescending;
    }];

    // Select exactly one default track of each media type. Container stream
    // indices are not a proxy for default-track selection: a non-default audio
    // stream may precede the actual default stream.
    FMETrackReader *firstVideo = nil, *firstAudio = nil;
    FMETrackReader *defaultVideo = nil, *defaultAudio = nil;
    for (FMETrackReader *track in _tracks) {
        CMMediaType type = CMFormatDescriptionGetMediaType(track.formatDescription);
        BOOL markedDefault = (_formatContext->streams[track.streamIndex]->disposition & AV_DISPOSITION_DEFAULT) != 0;
        if (type == kCMMediaType_Video) {
            if (!firstVideo) firstVideo = track;
            if (!defaultVideo && markedDefault) defaultVideo = track;
        } else if (type == kCMMediaType_Audio) {
            if (!firstAudio) firstAudio = track;
            if (!defaultAudio && markedDefault) defaultAudio = track;
        }
    }
    FMETrackReader *selectedVideo = defaultVideo ?: firstVideo;
    FMETrackReader *selectedAudio = defaultAudio ?: firstAudio;
    for (FMETrackReader *track in _tracks) {
        track.trackInfo.enabled = track == selectedVideo || track == selectedAudio;
    }

    if (_tracks.count == 0) {
        if (error) *error = FMEError(12, @"The file contains no audio or video tracks with a supported Core Media format.");
        fmeCloseFormatContext(&_formatContext);
        return nil;
    }
    return self;
}

- (BOOL)readAndAppendNextIndexedPacket:(NSError **)error {
    AVPacket *packet = av_packet_alloc();
    if (!packet) {
        if (error) *error = FMEError(21, @"Unable to allocate an FFmpeg packet while extending the index.");
        return NO;
    }
    int result = av_read_frame(_formatContext, packet);
    if (result < 0) {
        if (result == AVERROR_EOF) {
            _indexReachedEOF = YES;
        } else if (error) {
            NSError *sourceError = fmeStoredIOError(_formatContext);
            if (sourceError) {
                *error = sourceError;
            } else {
                char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
                av_strerror(result, detail, sizeof(detail));
                *error = FMEError(23, [NSString stringWithFormat:@"FFmpeg could not continue reading the media: %s", detail]);
            }
        }
        av_packet_free(&packet);
        return NO;
    }

    FMETrackReader *track = _tracksByStream[@(packet->stream_index)];
    if (track) {
        FMESample *sample = [FMESample new];
        sample.streamIndex = packet->stream_index;
        sample.pts = packet->pts;
        sample.dts = packet->dts;
        sample.duration = packet->duration;
        sample.filePosition = packet->pos;
        sample.packetSize = packet->size;
        sample.flags = packet->flags;
        sample.packetData = [NSData dataWithBytes:packet->data length:(NSUInteger)packet->size];
        [track appendIndexedSample:sample];
        // Keep the zero-copy fast path for nearby playback without retaining
        // the compressed payload of every unselected track for the whole file.
        [track discardCachedPacketDataBeforeLastSampleCount:256];
    }
    av_packet_free(&packet);
    return YES;
}

- (void)resetAudioDecodeStateForStream:(NSInteger)streamIndex {
    if (streamIndex < 0 || streamIndex >= _streamCount) return;
    [_audioDecodeLock lock];
    if (_audioDecoderContexts[streamIndex]) avcodec_flush_buffers(_audioDecoderContexts[streamIndex]);
    swr_free(&_audioResamplers[streamIndex]);
    _audioDecodeIndices[streamIndex] = -1;
    [_audioDecodeLock unlock];
}

- (void)trimIndexedWindowsIfNeededLocked {
    NSMutableArray<NSNumber *> *trimmedStreams = [NSMutableArray array];
    for (NSNumber *key in _tracksByStream) {
        FMETrackReader *track = _tracksByStream[key];
        if ([track trimIndexedSamplesToMaximumCount:4096 retainingCount:2048]) {
            [trimmedStreams addObject:key];
        }
    }
    if (trimmedStreams.count == 0) return;

    // Local decode indices are reassigned during compaction, so packet-reader
    // and decoder state keyed by those indices must be invalidated together.
    [_demuxLock lock];
    for (NSNumber *key in trimmedStreams) {
        NSInteger streamIndex = key.integerValue;
        fmeCloseFormatContext(&_readContexts[streamIndex]);
        _readIndices[streamIndex] = -1;
        [_lastPacketDataByStream removeObjectForKey:key];
    }
    [_demuxLock unlock];
    for (NSNumber *key in trimmedStreams) {
        [self resetAudioDecodeStateForStream:key.integerValue];
    }
}

- (void)compactIndexedWindowsIfNeeded {
    [_indexLock lock];
    [self trimIndexedWindowsIfNeededLocked];
    [_indexLock unlock];
}

- (BOOL)ensureSampleForStream:(NSInteger)streamIndex
                atDecodeIndex:(NSInteger)decodeIndex
                        error:(NSError **)error {
    [_indexLock lock];
    FMETrackReader *track = _tracksByStream[@(streamIndex)];
    while (track && decodeIndex >= (NSInteger)track.decodeSamples.count && !_indexReachedEOF) {
        if (![self readAndAppendNextIndexedPacket:error] && !_indexReachedEOF) break;
    }
    BOOL available = track && decodeIndex >= 0 && decodeIndex < (NSInteger)track.decodeSamples.count;
    [_indexLock unlock];
    return available;
}

- (BOOL)ensureSamplesForStream:(NSInteger)streamIndex
  throughPresentationTimestamp:(int64_t)timestamp
                          error:(NSError **)error {
    [_indexLock lock];
    FMETrackReader *track = _tracksByStream[@(streamIndex)];
    FMESample *currentFirst = track.presentationSamples.firstObject;
    FMESample *currentLast = track.presentationSamples.lastObject;
    int64_t firstTimestamp = currentFirst
        ? (currentFirst.pts == AV_NOPTS_VALUE ? currentFirst.dts : currentFirst.pts)
        : AV_NOPTS_VALUE;
    int64_t currentTimestamp = currentLast
        ? (currentLast.pts == AV_NOPTS_VALUE ? currentLast.dts : currentLast.pts)
        : AV_NOPTS_VALUE;
    int64_t maximumLinearGap = (int64_t)MAX(track.timeScale, 1) * 30;
    BOOL outsideCurrentWindow =
        (currentTimestamp != AV_NOPTS_VALUE && timestamp > currentTimestamp + maximumLinearGap) ||
        (firstTimestamp != AV_NOPTS_VALUE && timestamp < firstTimestamp);

    if (outsideCurrentWindow) {
        // MediaToolbox probes at the exact asset end while discovering track
        // bounds. Keep that metadata request bounded; other distant requests
        // are real seeks and get a fresh keyframe-aligned packet window.
        CMTime duration = CMTimeConvertScale(self.duration, track.timeScale, kCMTimeRoundingMethod_Default);
        BOOL probesAssetEnd = CMTIME_IS_NUMERIC(duration) &&
            timestamp >= duration.value - MAX((int64_t)track.timeScale, 1);
        if (probesAssetEnd) {
            [_indexLock unlock];
            return NO;
        }

        NSInteger seekStreamIndex = _primaryVideoStreamIndex >= 0
            ? _primaryVideoStreamIndex : streamIndex;
        AVStream *requestStream = _formatContext->streams[streamIndex];
        AVStream *seekStream = _formatContext->streams[seekStreamIndex];
        int64_t seekTimestamp = av_rescale_q(timestamp,
                                             requestStream->time_base,
                                             seekStream->time_base);
        int seekResult = avformat_seek_file(_formatContext,
                                            (int)seekStreamIndex,
                                            INT64_MIN,
                                            seekTimestamp,
                                            seekTimestamp,
                                            AVSEEK_FLAG_BACKWARD);
        if (seekResult < 0) {
            seekResult = av_seek_frame(_formatContext,
                                       (int)seekStreamIndex,
                                       seekTimestamp,
                                       AVSEEK_FLAG_BACKWARD);
        }
        if (seekResult < 0) {
            if (error) *error = FMEError(22, @"FFmpeg could not seek to the requested presentation time.");
            [_indexLock unlock];
            return NO;
        }
        avformat_flush(_formatContext);
        _indexReachedEOF = NO;

        for (NSNumber *readerKey in _tracksByStream) {
            FMETrackReader *readerTrack = _tracksByStream[readerKey];
            AVStream *readerStream = _formatContext->streams[readerKey.integerValue];
            int64_t readerTimestamp = av_rescale_q(timestamp,
                                                   requestStream->time_base,
                                                   readerStream->time_base);
            [readerTrack resetIndexedSamplesAtPresentationTimestamp:readerTimestamp];
        }
        [_demuxLock lock];
        for (unsigned index = 0; index < _streamCount; index++) {
            fmeCloseFormatContext(&_readContexts[index]);
            _readIndices[index] = -1;
        }
        [_lastPacketDataByStream removeAllObjects];
        [_demuxLock unlock];
        for (unsigned index = 0; index < _streamCount; index++) {
            [self resetAudioDecodeStateForStream:(NSInteger)index];
        }

        // Include enough packets after the cue/keyframe for decode reordering,
        // audio alignment, and immediate forward playback.
        static const NSUInteger seekPacketWindow = 512;
        for (NSUInteger index = 0; index < seekPacketWindow && !_indexReachedEOF; index++) {
            if (![self readAndAppendNextIndexedPacket:error]) break;
        }
        track = _tracksByStream[@(streamIndex)];
    }
    while (track && !_indexReachedEOF) {
        FMESample *last = track.presentationSamples.lastObject;
        int64_t lastTimestamp = last ? (last.pts == AV_NOPTS_VALUE ? last.dts : last.pts) : AV_NOPTS_VALUE;
        if (lastTimestamp != AV_NOPTS_VALUE && lastTimestamp >= timestamp) break;
        if (![self readAndAppendNextIndexedPacket:error] && !_indexReachedEOF) break;
    }
    [self trimIndexedWindowsIfNeededLocked];
    track = _tracksByStream[@(streamIndex)];
    FMESample *last = track.presentationSamples.lastObject;
    int64_t lastTimestamp = last ? (last.pts == AV_NOPTS_VALUE ? last.dts : last.pts) : AV_NOPTS_VALUE;
    BOOL covered = lastTimestamp != AV_NOPTS_VALUE && lastTimestamp >= timestamp;
    [_indexLock unlock];
    return covered || _indexReachedEOF;
}

- (void)dealloc {
    if (_readContexts) {
        for (unsigned index = 0; index < _streamCount; index++) {
            fmeCloseFormatContext(&_readContexts[index]);
        }
    }
    if (_audioDecoderContexts) {
        for (unsigned index = 0; index < _streamCount; index++) {
            avcodec_free_context(&_audioDecoderContexts[index]);
            swr_free(&_audioResamplers[index]);
        }
    }
    free(_readContexts);
    free(_readIndices);
    free(_audioDecoderContexts);
    free(_audioResamplers);
    free(_audioDecodeIndices);
    fmeCloseFormatContext(&_formatContext);
}

- (NSData *)copyPacketDataForSample:(FMESample *)sample error:(NSError **)error {
    [_demuxLock lock];
    NSData *resultData = nil;
    NSError *readError = nil;
    NSInteger streamIndex = sample.streamIndex;
    if (streamIndex < 0 || streamIndex >= _streamCount) {
        [_demuxLock unlock];
        if (error) *error = FMEError(19, @"The requested packet has an invalid stream index.");
        return nil;
    }

    if (sample.packetData) {
        // Packets discovered by the bounded/lazy index are already in memory.
        // Handing this payload straight to Core Media avoids reopening and
        // relocating the same Matroska block, which is particularly expensive
        // for sparse or network-backed files.
        resultData = sample.packetData;
        // Keep the payload attached while the sample remains in the bounded
        // window. Core Media can legitimately request the same packet from
        // multiple cursors; consuming it here forced a fragile timestamp seek
        // on the second request. Window pruning owns payload eviction.
        _readIndices[streamIndex] = sample.decodeIndex;
        _lastPacketDataByStream[@(streamIndex)] = resultData;
    } else if (_readIndices[streamIndex] == sample.decodeIndex) {
        resultData = _lastPacketDataByStream[@(streamIndex)];
    } else {
        AVFormatContext *reader = _readContexts[streamIndex];
        BOOL sequentialRequest = reader && _readIndices[streamIndex] + 1 == sample.decodeIndex;

        if (!reader || (!sequentialRequest && sample.decodeIndex == 0)) {
            fmeCloseFormatContext(&_readContexts[streamIndex]);
            // Stream discovery is already complete in the indexing context.  A
            // playback reader only needs Matroska headers; probing again can
            // scan gigabytes in files with sparse timestamps.
            reader = fmeOpenFormatContext(self.byteSource, NO, &readError);
            _readContexts[streamIndex] = reader;
            _readIndices[streamIndex] = -1;
            [_lastPacketDataByStream removeObjectForKey:@(streamIndex)];
            // Decode indices are local to the bounded packet window and reset
            // to zero after every distant seek. Only generation zero's first
            // packet is actually at the beginning of the file; a later local
            // index zero must seek to its timestamp before packet recovery.
            sequentialRequest = sample.decodeIndex == 0 && sample.windowGeneration == 0;
        }

        int seekResult = 0;
        if (reader && !sequentialRequest) {
            int64_t target = sample.dts != AV_NOPTS_VALUE ? sample.dts : sample.pts;
            seekResult = avformat_seek_file(reader,
                                            (int)streamIndex,
                                            INT64_MIN,
                                            target,
                                            target,
                                            AVSEEK_FLAG_BACKWARD);
            if (seekResult < 0) {
                seekResult = av_seek_frame(reader, (int)streamIndex, target, AVSEEK_FLAG_BACKWARD);
            }
            avformat_flush(reader);
        }

        if (reader && seekResult >= 0) {
            AVPacket *packet = av_packet_alloc();
            for (NSUInteger attempts = 0; packet && attempts < 20000 && av_read_frame(reader, packet) >= 0; attempts++) {
                BOOL sameStream = packet->stream_index == sample.streamIndex;
                BOOL sameDTS = sample.dts == AV_NOPTS_VALUE || packet->dts == sample.dts;
                BOOL samePTS = sample.pts == AV_NOPTS_VALUE || packet->pts == sample.pts;
                BOOL samePosition = sample.filePosition < 0 || packet->pos == sample.filePosition;
                // FFmpeg may synthesize a missing DTS while building the first
                // index window. A reopened demuxer can therefore report the
                // original AV_NOPTS_VALUE for the same packet. File position is
                // the strongest identity when Matroska supplies it; otherwise
                // accept either matching timestamp together with stream/size.
                BOOL packetMatches = sameStream && packet->size == sample.packetSize &&
                    (sameDTS || samePTS) &&
                    (sample.filePosition < 0 || samePosition);
                if (packetMatches) {
                    resultData = [NSData dataWithBytes:packet->data length:(NSUInteger)packet->size];
                    av_packet_unref(packet);
                    break;
                }
                if (sample.filePosition < 0 && sameStream && packet->dts != AV_NOPTS_VALUE &&
                    sample.dts != AV_NOPTS_VALUE && packet->dts > sample.dts) {
                    av_packet_unref(packet);
                    break;
                }
                av_packet_unref(packet);
            }
            av_packet_free(&packet);
            if (!resultData) readError = fmeStoredIOError(reader);
        }

        if (resultData) {
            _readIndices[streamIndex] = sample.decodeIndex;
            _lastPacketDataByStream[@(streamIndex)] = resultData;
        }
    }
    [_demuxLock unlock];

    if (!resultData && error) {
        *error = readError ?: FMEError(20, [NSString stringWithFormat:@"Unable to retrieve packet %ld from stream %ld.", (long)sample.decodeIndex, (long)sample.streamIndex]);
    }
    return resultData;
}

- (NSData *)copyPCMDataForDecodedAudioSample:(FMESample *)sample
                                   frameCount:(CMItemCount *)frameCount
                                        error:(NSError **)error {
    [_audioDecodeLock lock];
    NSData *resultData = nil;
    NSData *compressedData = nil;
    AVPacket *packet = NULL;
    AVFrame *frame = NULL;
    AVChannelLayout outputLayout = {0};
    AVChannelLayout inputLayout = {0};
    NSInteger streamIndex = sample.streamIndex;
    int result = 0;
    AVCodecParameters *parameters = NULL;
    AVCodecContext *decoder = NULL;
    SwrContext *resampler = NULL;
    int outputRate = 0;
    int inputRate = 0;
    int maximumFrames = 0;
    int convertedFrames = 0;
    const enum AVSampleFormat outputSampleFormat = AV_SAMPLE_FMT_S16;
    const NSUInteger outputBytesPerSample = sizeof(int16_t);
    NSMutableData *pcmData = nil;
    FMEPCMCacheEntry *cachedPCM = nil;
    FMEPCMCacheEntry *cacheEntry = nil;

    if (streamIndex < 0 || streamIndex >= _streamCount) {
        if (error) *error = FMEError(50, @"The requested decoded-audio stream is invalid.");
        goto cleanup;
    }
    parameters = _formatContext->streams[streamIndex]->codecpar;
    BOOL supportedCodec = parameters->codec_id == AV_CODEC_ID_DTS ||
        (parameters->codec_id == AV_CODEC_ID_AAC &&
         (parameters->profile == AV_PROFILE_AAC_HE ||
          parameters->profile == AV_PROFILE_AAC_HE_V2));
    if (!supportedCodec) {
        if (error) *error = FMEError(50, @"The requested stream is not configured for FFmpeg PCM decoding.");
        goto cleanup;
    }

    // Cache decoded packets by sample identity. Core Media may request the
    // same LPCM packet from several cursors during playback and seeking.
    cachedPCM = [_pcmCache objectForKey:sample];
    if (cachedPCM) {
        resultData = cachedPCM.data;
        if (frameCount) *frameCount = cachedPCM.frameCount;
        goto cleanup;
    }

    compressedData = [self copyPacketDataForSample:sample error:error];
    if (!compressedData) goto cleanup;

    decoder = _audioDecoderContexts[streamIndex];
    if (!decoder) {
        const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
        if (!codec) {
            if (error) *error = FMEError(51, @"The required FFmpeg audio decoder is unavailable.");
            goto cleanup;
        }
        decoder = avcodec_alloc_context3(codec);
        if (!decoder || avcodec_parameters_to_context(decoder, parameters) < 0 ||
            avcodec_open2(decoder, codec, NULL) < 0) {
            avcodec_free_context(&decoder);
            if (error) *error = FMEError(52, @"FFmpeg could not initialize the audio decoder.");
            goto cleanup;
        }
        _audioDecoderContexts[streamIndex] = decoder;
    }

    if (_audioDecodeIndices[streamIndex] + 1 != sample.decodeIndex) {
        avcodec_flush_buffers(decoder);
        swr_free(&_audioResamplers[streamIndex]);

        // Stateful DTS-HD MA/XLL and HE-AAC SBR both benefit from decoder
        // history after a seek. Matroska video-keyframe seeks leave ample
        // audio preroll in the lazy window, so warm up with up to 32 packets.
        FMETrackReader *track = _tracksByStream[@(streamIndex)];
        NSArray<FMESample *> *decodeSamples = track.decodeSamples;
        NSInteger primeStart = MAX(sample.decodeIndex - 32, 0);
        AVFrame *primeFrame = av_frame_alloc();
        if (!primeFrame) {
            if (error) *error = FMEError(60, @"Unable to allocate an audio preroll frame.");
            goto cleanup;
        }
        for (NSInteger index = primeStart; index < sample.decodeIndex; index++) {
            if (index >= (NSInteger)decodeSamples.count) {
                result = AVERROR(EINVAL);
                break;
            }
            FMESample *primeSample = decodeSamples[(NSUInteger)index];
            NSData *primeData = [self copyPacketDataForSample:primeSample error:error];
            AVPacket *primePacket = av_packet_alloc();
            if (!primeData || !primePacket || primeData.length > INT_MAX ||
                av_new_packet(primePacket, (int)primeData.length) < 0) {
                av_packet_free(&primePacket);
                result = AVERROR(ENOMEM);
                break;
            }
            memcpy(primePacket->data, primeData.bytes, primeData.length);
            primePacket->pts = primeSample.pts;
            primePacket->dts = primeSample.dts;
            result = avcodec_send_packet(decoder, primePacket);
            av_packet_free(&primePacket);
            if (result < 0) break;
            result = avcodec_receive_frame(decoder, primeFrame);
            if (result < 0) break;
            av_frame_unref(primeFrame);
        }
        av_frame_free(&primeFrame);
        if (result < 0) {
            char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
            av_strerror(result, detail, sizeof(detail));
            if (error) *error = FMEError(61, [NSString stringWithFormat:@"FFmpeg audio preroll failed: %s", detail]);
            goto cleanup;
        }
        _audioDecodeIndices[streamIndex] = sample.decodeIndex - 1;
    }

    packet = av_packet_alloc();
    frame = av_frame_alloc();
    if (!packet || !frame || compressedData.length > INT_MAX ||
        av_new_packet(packet, (int)compressedData.length) < 0) {
        if (error) *error = FMEError(53, @"Unable to allocate an audio decode packet.");
        goto cleanup;
    }
    memcpy(packet->data, compressedData.bytes, compressedData.length);
    packet->pts = sample.pts;
    packet->dts = sample.dts;

    result = avcodec_send_packet(decoder, packet);
    if (result >= 0) result = avcodec_receive_frame(decoder, frame);
    if (result < 0) {
        char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(result, detail, sizeof(detail));
        if (error) *error = FMEError(54, [NSString stringWithFormat:@"FFmpeg could not decode audio: %s", detail]);
        goto cleanup;
    }

    // Present DTS as stereo LPCM to keep QuickTime out of its problematic
    // multichannel spatial-rendering path. libswresample performs the matrix
    // downmix from the decoder's native channel layout.
    av_channel_layout_default(&outputLayout, 2);
    result = 0;
    if (result < 0 || outputLayout.nb_channels <= 0) {
        if (error) *error = FMEError(55, @"The DTS stream has no usable output channel layout.");
        goto cleanup;
    }
    if (frame->ch_layout.nb_channels > 0) {
        result = av_channel_layout_copy(&inputLayout, &frame->ch_layout);
    } else {
        result = 0;
        av_channel_layout_default(&inputLayout, outputLayout.nb_channels);
    }
    if (result < 0) {
        if (error) *error = FMEError(56, @"The decoded DTS frame has no usable channel layout.");
        goto cleanup;
    }

    resampler = _audioResamplers[streamIndex];
    outputRate = parameters->sample_rate > 0 ? parameters->sample_rate : frame->sample_rate;
    inputRate = frame->sample_rate > 0 ? frame->sample_rate : outputRate;
    if (!resampler) {
        result = swr_alloc_set_opts2(&resampler,
                                     &outputLayout,
                                     outputSampleFormat,
                                     outputRate,
                                     &inputLayout,
                                     (enum AVSampleFormat)frame->format,
                                     inputRate,
                                     0,
                                     NULL);
        if (result >= 0) result = swr_init(resampler);
        if (result < 0) {
            swr_free(&resampler);
            if (error) *error = FMEError(57, @"FFmpeg could not initialize DTS PCM conversion.");
            goto cleanup;
        }
        _audioResamplers[streamIndex] = resampler;
    }

    maximumFrames = swr_get_out_samples(resampler, frame->nb_samples);
    if (maximumFrames < 0 || (NSUInteger)maximumFrames > NSUIntegerMax /
        ((NSUInteger)outputLayout.nb_channels * outputBytesPerSample)) {
        if (error) *error = FMEError(58, @"The decoded DTS frame is too large.");
        goto cleanup;
    }
    pcmData = [NSMutableData dataWithLength:(NSUInteger)maximumFrames *
               (NSUInteger)outputLayout.nb_channels * outputBytesPerSample];
    uint8_t *outputPlanes[1] = { pcmData.mutableBytes };
    convertedFrames = swr_convert(resampler,
                                  outputPlanes,
                                  maximumFrames,
                                  (const uint8_t **)frame->extended_data,
                                  frame->nb_samples);
    if (convertedFrames < 0) {
        if (error) *error = FMEError(59, @"FFmpeg could not convert decoded DTS to PCM.");
        goto cleanup;
    }
    pcmData.length = (NSUInteger)convertedFrames * (NSUInteger)outputLayout.nb_channels * outputBytesPerSample;
    resultData = [pcmData copy];
    if (frameCount) *frameCount = convertedFrames;
    _audioDecodeIndices[streamIndex] = sample.decodeIndex;
    cacheEntry = [FMEPCMCacheEntry new];
    cacheEntry.data = resultData;
    cacheEntry.frameCount = convertedFrames;
    [_pcmCache setObject:cacheEntry forKey:sample cost:resultData.length];

cleanup:
    av_channel_layout_uninit(&inputLayout);
    av_channel_layout_uninit(&outputLayout);
    av_frame_free(&frame);
    av_packet_free(&packet);
    [_audioDecodeLock unlock];
    return resultData;
}

@end
