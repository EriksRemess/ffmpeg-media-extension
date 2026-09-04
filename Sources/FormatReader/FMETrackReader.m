#import "FMETrackReader.h"
#import "FMESampleCursor.h"

#include <libavcodec/packet.h>

@interface FMETrackReader ()
@property(nonatomic, readwrite) FMEAsset *asset;
@property(nonatomic, readwrite) NSInteger streamIndex;
@property(nonatomic, readwrite) int timeScale;
@property(nonatomic, readwrite) CMFormatDescriptionRef formatDescription;
@property(nonatomic, readwrite) NSArray<FMESample *> *decodeSamples;
@property(nonatomic, readwrite) NSArray<FMESample *> *presentationSamples;
@property(nonatomic, readwrite) METrackInfo *trackInfo;
@property(nonatomic, readwrite) NSInteger windowGeneration;
@property(nonatomic, readwrite) int64_t windowTargetTimestamp;
@property(nonatomic, readwrite) FMESample *terminalSample;
@property(nonatomic, readwrite) BOOL currentWindowReachedKnownEnd;
@property(nonatomic, readwrite) BOOL decodesDTSToPCM;
@property(nonatomic, readwrite) UInt32 decodedPCMFramesPerPacket;
@property(nonatomic) NSUInteger packetDataDiscardedThrough;
@end

@implementation FMETrackReader

- (NSArray<FMESample *> *)decodeSamples {
    @synchronized (self) {
        return [_decodeSamples copy];
    }
}

- (NSArray<FMESample *> *)presentationSamples {
    @synchronized (self) {
        return [_presentationSamples copy];
    }
}

- (instancetype)initWithAsset:(FMEAsset *)asset
                  streamIndex:(NSInteger)streamIndex
                    timeScale:(int)timeScale
             formatDescription:(CMFormatDescriptionRef)formatDescription
                     trackInfo:(METrackInfo *)trackInfo
               decodesDTSToPCM:(BOOL)decodesDTSToPCM
      decodedPCMFramesPerPacket:(UInt32)decodedPCMFramesPerPacket
                       samples:(NSArray<FMESample *> *)samples {
    if (!(self = [super init])) return nil;
    _asset = asset;
    _streamIndex = streamIndex;
    _timeScale = MAX(timeScale, 1);
    _formatDescription = CFRetain(formatDescription);
    _trackInfo = trackInfo;
    _decodesDTSToPCM = decodesDTSToPCM;
    _decodedPCMFramesPerPacket = decodedPCMFramesPerPacket;
    _windowGeneration = 0;
    _windowTargetTimestamp = 0;
    _decodeSamples = [samples mutableCopy];
    for (FMESample *sample in _decodeSamples) sample.windowGeneration = _windowGeneration;

    // Some Matroska H.264 streams omit DTS for the leading reordered frames.
    // Core Media needs a monotonic decode timeline to begin playback, so work
    // backwards from the first packet that does carry a DTS. This preserves
    // the container PTS values while supplying only the missing decode times.
    NSInteger firstKnownDTS = NSNotFound;
    for (NSUInteger index = 0; index < _decodeSamples.count; index++) {
        if (_decodeSamples[index].dts != INT64_MIN) {
            firstKnownDTS = (NSInteger)index;
            break;
        }
    }
    if (firstKnownDTS != NSNotFound && firstKnownDTS > 0) {
        int64_t nextDTS = _decodeSamples[(NSUInteger)firstKnownDTS].dts;
        for (NSInteger index = firstKnownDTS - 1; index >= 0; index--) {
            FMESample *sample = _decodeSamples[(NSUInteger)index];
            int64_t duration = sample.duration > 0 ? sample.duration : 1;
            nextDTS -= duration;
            sample.dts = nextDTS;
        }
    }
    _presentationSamples = [[samples sortedArrayUsingComparator:^NSComparisonResult(FMESample *a, FMESample *b) {
        int64_t aTime = a.pts == INT64_MIN ? a.dts : a.pts;
        int64_t bTime = b.pts == INT64_MIN ? b.dts : b.pts;
        if (aTime < bTime) return NSOrderedAscending;
        if (aTime > bTime) return NSOrderedDescending;
        if (a.decodeIndex < b.decodeIndex) return NSOrderedAscending;
        if (a.decodeIndex > b.decodeIndex) return NSOrderedDescending;
        return NSOrderedSame;
    }] mutableCopy];
    [_presentationSamples enumerateObjectsUsingBlock:^(FMESample *sample, NSUInteger index, BOOL *stop) {
        sample.presentationIndex = (NSInteger)index;
    }];

    for (NSUInteger index = 0; index + 1 < _decodeSamples.count; index++) {
        FMESample *sample = _decodeSamples[index];
        if (sample.duration <= 0) {
            FMESample *next = _decodeSamples[index + 1];
            int64_t currentTime = sample.dts == INT64_MIN ? sample.pts : sample.dts;
            int64_t nextTime = next.dts == INT64_MIN ? next.pts : next.dts;
            if (currentTime != INT64_MIN && nextTime > currentTime) sample.duration = nextTime - currentTime;
        }
    }

    // Boundary discovery needs a stable cursor at the real track end.  The
    // currently indexed packet window is deliberately bounded and therefore
    // must not be advertised as the last sample in the asset.
    CMTime terminalTime = CMTimeConvertScale(asset.duration, _timeScale,
                                              kCMTimeRoundingMethod_Default);
    if (CMTIME_IS_NUMERIC(terminalTime)) {
        FMESample *terminal = [FMESample new];
        terminal.streamIndex = streamIndex;
        terminal.decodeIndex = NSIntegerMax / 4;
        terminal.presentationIndex = NSIntegerMax / 4;
        terminal.pts = MAX(terminalTime.value - 1, 0);
        terminal.dts = terminal.pts;
        terminal.duration = 1;
        terminal.filePosition = -1;
        terminal.packetSize = 0;
        terminal.flags = AV_PKT_FLAG_KEY;
        terminal.windowGeneration = -1;
        terminal.syntheticTerminal = YES;
        _terminalSample = terminal;
    }

    return self;
}

- (void)appendIndexedSample:(FMESample *)sample {
    @synchronized (self) {
    NSMutableArray<FMESample *> *decode = (NSMutableArray<FMESample *> *)_decodeSamples;
    NSMutableArray<FMESample *> *presentation = (NSMutableArray<FMESample *> *)_presentationSamples;

    FMESample *previous = decode.lastObject;
    if (previous && previous.duration <= 0) {
        int64_t previousTime = previous.dts == INT64_MIN ? previous.pts : previous.dts;
        int64_t sampleTime = sample.dts == INT64_MIN ? sample.pts : sample.dts;
        if (previousTime != INT64_MIN && sampleTime > previousTime) previous.duration = sampleTime - previousTime;
    }
    sample.windowGeneration = self.windowGeneration;
    sample.decodeIndex = (NSInteger)decode.count;
    [decode addObject:sample];

    if (sample.dts != INT64_MIN && decode.count > 1) {
        int64_t nextDTS = sample.dts;
        for (NSInteger index = (NSInteger)decode.count - 2; index >= 0; index--) {
            FMESample *leading = decode[(NSUInteger)index];
            if (leading.dts != INT64_MIN) break;
            int64_t duration = leading.duration > 0 ? leading.duration : 1;
            nextDTS -= duration;
            leading.dts = nextDTS;
        }
    }

    int64_t value = sample.pts == INT64_MIN ? sample.dts : sample.pts;
    NSUInteger insertion = presentation.count;
    while (insertion > 0) {
        FMESample *candidate = presentation[insertion - 1];
        int64_t candidateValue = candidate.pts == INT64_MIN ? candidate.dts : candidate.pts;
        if (candidateValue <= value) break;
        insertion--;
    }
    [presentation insertObject:sample atIndex:insertion];
    for (NSUInteger index = insertion; index < presentation.count; index++) {
        presentation[index].presentationIndex = (NSInteger)index;
    }
    }
}

- (void)resetIndexedSamplesAtPresentationTimestamp:(int64_t)timestamp {
    @synchronized (self) {
        self.windowGeneration += 1;
        self.windowTargetTimestamp = timestamp;
        for (FMESample *sample in _decodeSamples) sample.packetData = nil;
        [(NSMutableArray<FMESample *> *)_decodeSamples removeAllObjects];
        [(NSMutableArray<FMESample *> *)_presentationSamples removeAllObjects];
        self.packetDataDiscardedThrough = 0;
        self.currentWindowReachedKnownEnd = NO;
    }
}

- (void)markCurrentWindowReachedKnownEnd {
    @synchronized (self) {
        self.currentWindowReachedKnownEnd = YES;
    }
}

- (FMESample *)sampleInCurrentWindowAtPresentationTime:(CMTime)time {
    @synchronized (self) {
    if (_presentationSamples.count == 0) return nil;
    CMTime converted = CMTimeConvertScale(time, self.timeScale, kCMTimeRoundingMethod_Default);
    int64_t target = converted.value;
    NSInteger low = 0;
    NSInteger high = (NSInteger)_presentationSamples.count - 1;
    NSInteger result = 0;
    while (low <= high) {
        NSInteger middle = low + (high - low) / 2;
        FMESample *sample = _presentationSamples[(NSUInteger)middle];
        int64_t value = sample.pts == INT64_MIN ? sample.dts : sample.pts;
        if (value <= target) {
            result = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    return _presentationSamples[(NSUInteger)result];
    }
}

- (FMESample *)sampleInCurrentWindowMatchingSample:(FMESample *)sample {
    @synchronized (self) {
        for (FMESample *candidate in _decodeSamples) {
            BOOL samePosition = sample.filePosition >= 0 && candidate.filePosition == sample.filePosition;
            BOOL sameDTS = sample.dts != INT64_MIN && candidate.dts != INT64_MIN &&
                candidate.dts == sample.dts;
            BOOL samePTS = sample.pts != INT64_MIN && candidate.pts != INT64_MIN &&
                candidate.pts == sample.pts;
            if ((samePosition || sameDTS || samePTS) && candidate.packetSize == sample.packetSize) return candidate;
        }
        return nil;
    }
}

- (BOOL)isSampleInCurrentWindow:(FMESample *)sample {
    @synchronized (self) {
        NSInteger index = sample.decodeIndex;
        return sample.windowGeneration == _windowGeneration && index >= 0 &&
            index < (NSInteger)_decodeSamples.count && _decodeSamples[(NSUInteger)index] == sample;
    }
}

- (BOOL)trimIndexedSamplesToMaximumCount:(NSUInteger)maximumCount
                          retainingCount:(NSUInteger)retainingCount {
    @synchronized (self) {
        NSMutableArray<FMESample *> *decode = (NSMutableArray<FMESample *> *)_decodeSamples;
        if (decode.count <= maximumCount || retainingCount == 0) return NO;
        retainingCount = MIN(retainingCount, decode.count);
        NSUInteger removedCount = decode.count - retainingCount;
        [decode removeObjectsInRange:NSMakeRange(0, removedCount)];
        self.packetDataDiscardedThrough = self.packetDataDiscardedThrough > removedCount
            ? self.packetDataDiscardedThrough - removedCount : 0;

        self.windowGeneration += 1;
        for (NSUInteger index = 0; index < decode.count; index++) {
            decode[index].decodeIndex = (NSInteger)index;
            decode[index].windowGeneration = self.windowGeneration;
        }
        _presentationSamples = [[decode sortedArrayUsingComparator:^NSComparisonResult(FMESample *a, FMESample *b) {
            int64_t aTime = a.pts == INT64_MIN ? a.dts : a.pts;
            int64_t bTime = b.pts == INT64_MIN ? b.dts : b.pts;
            if (aTime < bTime) return NSOrderedAscending;
            if (aTime > bTime) return NSOrderedDescending;
            if (a.decodeIndex < b.decodeIndex) return NSOrderedAscending;
            if (a.decodeIndex > b.decodeIndex) return NSOrderedDescending;
            return NSOrderedSame;
        }] mutableCopy];
        [_presentationSamples enumerateObjectsUsingBlock:^(FMESample *entry, NSUInteger index, BOOL *stop) {
            entry.presentationIndex = (NSInteger)index;
        }];
        FMESample *first = _presentationSamples.firstObject;
        if (first) self.windowTargetTimestamp = first.pts == INT64_MIN ? first.dts : first.pts;
        return YES;
    }
}

- (void)discardCachedPacketDataBeforeLastSampleCount:(NSUInteger)sampleCount {
    @synchronized (self) {
        if (_decodeSamples.count <= sampleCount) return;
        NSUInteger end = _decodeSamples.count - sampleCount;
        NSUInteger start = MIN(self.packetDataDiscardedThrough, end);
        for (NSUInteger index = start; index < end; index++) {
            _decodeSamples[index].packetData = nil;
        }
        self.packetDataDiscardedThrough = end;
    }
}

- (void)dealloc {
    if (_formatDescription) CFRelease(_formatDescription);
}

- (FMESample *)sampleAtPresentationTime:(CMTime)time error:(NSError **)error {
    @synchronized (self.asset) {
    if (CMTIME_IS_POSITIVE_INFINITY(time)) {
        return self.terminalSample ?: self.presentationSamples.lastObject;
    }
    if (CMTIME_IS_NEGATIVE_INFINITY(time)) {
        if (![self.asset ensureSamplesForStream:self.streamIndex
                    throughPresentationTimestamp:0
                                            error:error]) return nil;
        return self.presentationSamples.firstObject;
    }
    CMTime converted = CMTimeConvertScale(time, self.timeScale, kCMTimeRoundingMethod_Default);
    if (!CMTIME_IS_NUMERIC(converted)) {
        if (error) *error = FMEMediaError(MEErrorInvalidParameter, @"The requested presentation timestamp is invalid.");
        return nil;
    }
    CMTime duration = CMTimeConvertScale(self.asset.duration, self.timeScale,
                                         kCMTimeRoundingMethod_Default);
    if (self.terminalSample && CMTIME_IS_NUMERIC(duration) &&
        converted.value >= duration.value) {
        return self.terminalSample;
    }
    if (![self.asset ensureSamplesForStream:self.streamIndex
               throughPresentationTimestamp:converted.value
                                       error:error]) return nil;
    return [self sampleInCurrentWindowAtPresentationTime:time];
    }
}

- (BOOL)samplesEarlierThanSample:(FMESample *)sample mayHavePTSAfterSample:(FMESample *)other {
    int64_t otherPTS = other.pts == INT64_MIN ? other.dts : other.pts;
    if (otherPTS == INT64_MIN || sample.decodeIndex < 0) return YES;
    NSArray<FMESample *> *decodeSamples = self.decodeSamples;
    NSInteger end = MIN(sample.decodeIndex, (NSInteger)decodeSamples.count);
    for (NSInteger index = 0; index < end; index++) {
        FMESample *candidate = decodeSamples[(NSUInteger)index];
        int64_t pts = candidate.pts == INT64_MIN ? candidate.dts : candidate.pts;
        if (pts != INT64_MIN && pts > otherPTS) return YES;
    }
    return NO;
}

- (BOOL)samplesLaterThanSample:(FMESample *)sample mayHavePTSBeforeSample:(FMESample *)other {
    int64_t otherPTS = other.pts == INT64_MIN ? other.dts : other.pts;
    if (otherPTS == INT64_MIN || sample.decodeIndex < 0) return YES;
    NSArray<FMESample *> *decodeSamples = self.decodeSamples;
    NSInteger start = MAX(sample.decodeIndex + 1, 0);
    for (NSInteger index = start; index < (NSInteger)decodeSamples.count; index++) {
        FMESample *candidate = decodeSamples[(NSUInteger)index];
        int64_t pts = candidate.pts == INT64_MIN ? candidate.dts : candidate.pts;
        if (pts != INT64_MIN && pts < otherPTS) return YES;
    }
    return NO;
}

- (void)loadTrackInfoWithCompletionHandler:(void (^)(METrackInfo *, NSError *))completionHandler {
    completionHandler(self.trackInfo, nil);
}

- (void)generateSampleCursorAtPresentationTimeStamp:(CMTime)presentationTimeStamp
                                  completionHandler:(void (^)(id<MESampleCursor>, NSError *))completionHandler {
    NSError *error = nil;
    FMESample *sample = [self sampleAtPresentationTime:presentationTimeStamp error:&error];
    if (!sample) {
        completionHandler(nil, error ?: FMEMediaError(MEErrorNoSamples, @"The track contains no media samples."));
        return;
    }
    completionHandler([[FMESampleCursor alloc] initWithTrack:self sample:sample], nil);
}

- (void)generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:(void (^)(id<MESampleCursor>, NSError *))completionHandler {
    @synchronized (self.asset) {
    NSError *error = nil;
    // Another client request (notably a last-sample query used while QuickTime
    // prepares an item) may have moved the shared bounded index to the tail.
    // Reposition the window before choosing its first element; otherwise this
    // method can incorrectly advertise a tail packet as the track's first
    // decode-order sample.
    [self.asset ensureSamplesForStream:self.streamIndex
          throughPresentationTimestamp:0
                                  error:&error];
    FMESample *sample = self.decodeSamples.firstObject;
    completionHandler(sample ? [[FMESampleCursor alloc] initWithTrack:self sample:sample] : nil,
                      sample ? nil : (error ?: FMEMediaError(MEErrorNoSamples, @"The track contains no media samples.")));
    }
}

- (void)generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:(void (^)(id<MESampleCursor>, NSError *))completionHandler {
    @synchronized (self.asset) {
    FMESample *sample = self.terminalSample ?: self.decodeSamples.lastObject;
    completionHandler(sample ? [[FMESampleCursor alloc] initWithTrack:self sample:sample] : nil,
                      sample ? nil : FMEMediaError(MEErrorNoSamples, @"The track contains no media samples."));
    }
}

- (void)loadUneditedDurationWithCompletionHandler:(void (^)(CMTime, NSError *))completionHandler {
    completionHandler(self.asset.duration, nil);
}

- (void)loadMetadataWithCompletionHandler:(void (^)(NSArray<AVMetadataItem *> *, NSError *))completionHandler {
    completionHandler(@[], nil);
}

@end
