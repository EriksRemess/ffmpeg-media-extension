#import "FMECommon.h"

@class FMETrackReader;
@class FMESample;
struct AVPacket;

NS_ASSUME_NONNULL_BEGIN

@interface FMEAsset : NSObject
@property(nonatomic, readonly) MEByteSource *byteSource;
@property(nonatomic, readonly) CMTime duration;
@property(nonatomic, readonly) NSArray<FMETrackReader *> *tracks;
- (nullable instancetype)initWithByteSource:(MEByteSource *)byteSource error:(NSError **)error;
- (nullable NSData *)copyPacketDataForSample:(FMESample *)sample error:(NSError **)error;
- (nullable NSData *)copyPCMDataForDecodedAudioSample:(FMESample *)sample
                                  frameCount:(CMItemCount *)frameCount
                                       error:(NSError **)error;
- (BOOL)ensureSampleForStream:(NSInteger)streamIndex
                atDecodeIndex:(NSInteger)decodeIndex
                        error:(NSError **)error;
- (BOOL)ensureSamplesForStream:(NSInteger)streamIndex
  throughPresentationTimestamp:(int64_t)timestamp
                          error:(NSError **)error;
- (void)compactIndexedWindowsIfNeeded;
- (nullable FMESample *)lastSampleForStream:(NSInteger)streamIndex error:(NSError **)error;
- (nullable FMESample *)lastPresentationSampleForStream:(NSInteger)streamIndex error:(NSError **)error;
- (BOOL)extendWindowBeforeSample:(FMESample *)sample error:(NSError **)error;
@end

@interface FMESample : NSObject
// Samples are shared by independent cursors while the indexer may compact its
// window or evict payloads. Atomic accessors keep those individual reads and
// writes safe; multi-field index changes and cursor operations share the asset transaction.
@property(atomic) NSInteger streamIndex;
@property(atomic) NSInteger decodeIndex;
@property(atomic) NSInteger presentationIndex;
@property(atomic) int64_t pts;
@property(atomic) int64_t dts;
@property(atomic) int64_t duration;
@property(atomic) int64_t filePosition;
@property(atomic) int packetSize;
@property(atomic) int flags;
@property(atomic, nullable) NSData *packetData;
@property(atomic) NSInteger windowGeneration;
- (BOOL)matchesSample:(FMESample *)sample;
- (BOOL)matchesPacket:(const struct AVPacket *)packet;
@end

NS_ASSUME_NONNULL_END
