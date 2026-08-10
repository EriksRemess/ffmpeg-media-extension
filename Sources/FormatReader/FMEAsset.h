#import "FMECommon.h"

@class FMETrackReader;
@class FMESample;

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
@end

@interface FMESample : NSObject
@property(nonatomic) NSInteger streamIndex;
@property(nonatomic) NSInteger decodeIndex;
@property(nonatomic) NSInteger presentationIndex;
@property(nonatomic) int64_t pts;
@property(nonatomic) int64_t dts;
@property(nonatomic) int64_t duration;
@property(nonatomic) int64_t filePosition;
@property(nonatomic) int packetSize;
@property(nonatomic) int flags;
@property(nonatomic, nullable) NSData *packetData;
@property(nonatomic) NSInteger windowGeneration;
@property(nonatomic) BOOL syntheticTerminal;
@end

NS_ASSUME_NONNULL_END
