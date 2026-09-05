#import "FMEAsset.h"

NS_ASSUME_NONNULL_BEGIN

@interface FMETrackReader : NSObject <METrackReader>
// The format reader and its cursors own the asset; the index owns its tracks.
@property(nonatomic, weak, readonly) FMEAsset *asset;
@property(nonatomic, readonly) NSInteger streamIndex;
@property(nonatomic, readonly) int timeScale;
@property(nonatomic, readonly) CMFormatDescriptionRef formatDescription;
@property(nonatomic, readonly) NSArray<FMESample *> *decodeSamples;
@property(nonatomic, readonly) NSArray<FMESample *> *presentationSamples;
@property(nonatomic, readonly) METrackInfo *trackInfo;
@property(nonatomic, readonly) NSInteger windowGeneration;
@property(nonatomic, readonly) int64_t windowTargetTimestamp;
@property(nonatomic, readonly, nullable) FMESample *terminalSample;
@property(nonatomic, readonly, nullable) FMESample *lastPresentationSample;
@property(nonatomic, readonly) BOOL currentWindowReachedKnownEnd;
@property(nonatomic, readonly) BOOL currentWindowStartsAtBeginning;
@property(nonatomic, readonly) BOOL decodesDTSToPCM;
@property(nonatomic, readonly) UInt32 decodedPCMFramesPerPacket;
- (instancetype)initWithAsset:(FMEAsset *)asset
                  streamIndex:(NSInteger)streamIndex
                    timeScale:(int)timeScale
             formatDescription:(CMFormatDescriptionRef)formatDescription
                     trackInfo:(METrackInfo *)trackInfo
               decodesDTSToPCM:(BOOL)decodesDTSToPCM
      decodedPCMFramesPerPacket:(UInt32)decodedPCMFramesPerPacket
                       samples:(NSArray<FMESample *> *)samples;
- (nullable FMESample *)sampleAtPresentationTime:(CMTime)time error:(NSError **)error;
- (BOOL)samplesEarlierThanSample:(FMESample *)sample mayHavePTSAfterSample:(FMESample *)other;
- (BOOL)samplesLaterThanSample:(FMESample *)sample mayHavePTSBeforeSample:(FMESample *)other;
- (void)appendIndexedSample:(FMESample *)sample;
- (void)resetIndexedSamplesAtPresentationTimestamp:(int64_t)timestamp;
- (nullable FMESample *)sampleInCurrentWindowAtPresentationTime:(CMTime)time;
- (nullable FMESample *)sampleInCurrentWindowMatchingSample:(FMESample *)sample;
- (BOOL)isSampleInCurrentWindow:(FMESample *)sample;
- (void)markCurrentWindowReachedKnownEnd;
- (void)setLastSample:(FMESample *)sample presentationSample:(FMESample *)presentationSample;
- (BOOL)trimIndexedSamplesToMaximumCount:(NSUInteger)maximumCount
                          retainingCount:(NSUInteger)retainingCount;
- (void)discardCachedPacketDataBeforeLastSampleCount:(NSUInteger)sampleCount;
@end

NS_ASSUME_NONNULL_END
