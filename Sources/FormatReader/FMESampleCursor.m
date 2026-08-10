#import "FMESampleCursor.h"

#include <libavformat/avformat.h>

@interface FMESampleCursor ()
@property(nonatomic) FMETrackReader *track;
@property(nonatomic) FMESample *sample;
@property(nonatomic) BOOL hasDeliveredCurrentSample;
@property(nonatomic) UInt32 pcmFrameOffset;
@end

@implementation FMESampleCursor

- (BOOL)synchronizeWithCurrentWindowForDataAccess:(NSError **)error {
    if (self.sample.syntheticTerminal) return YES;
    if (self.sample.windowGeneration == self.track.windowGeneration) return YES;

    int64_t value = self.sample.pts == AV_NOPTS_VALUE ? self.sample.dts : self.sample.pts;
    if (value == AV_NOPTS_VALUE) {
        if (error) *error = FMEMediaError(MEErrorNoSamples, @"A stale cursor has no presentation timestamp.");
        return NO;
    }
    if (![self.track.asset ensureSamplesForStream:self.track.streamIndex
                      throughPresentationTimestamp:value
                                              error:error]) return NO;
    FMESample *replacement = [self.track sampleInCurrentWindowMatchingSample:self.sample];
    if (!replacement) {
        replacement = [self.track sampleInCurrentWindowAtPresentationTime:CMTimeMake(value, self.track.timeScale)];
    }
    if (!replacement) {
        if (error) *error = FMEMediaError(MEErrorNoSamples, @"The cursor sample is no longer available.");
        return NO;
    }
    self.sample = replacement;
    self.hasDeliveredCurrentSample = NO;
    return YES;
}

- (instancetype)initWithTrack:(FMETrackReader *)track sample:(FMESample *)sample {
    if ((self = [super init])) {
        _track = track;
        _sample = sample;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    FMESampleCursor *copy = [[[self class] allocWithZone:zone] initWithTrack:self.track sample:self.sample];
    copy.hasDeliveredCurrentSample = self.hasDeliveredCurrentSample;
    copy.pcmFrameOffset = self.pcmFrameOffset;
    return copy;
}

- (int32_t)decodedPCMSampleRate {
    if (!self.track.decodesDTSToPCM) return 0;
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(
            (CMAudioFormatDescriptionRef)self.track.formatDescription);
    return asbd ? (int32_t)llround(asbd->mSampleRate) : 0;
}

- (BOOL)usesPCMFrameGranularCursors {
    return YES;
}

- (CMTime)continuousPCMTimeUsingDecodeTimestamp:(BOOL)useDecodeTimestamp {
    int32_t sampleRate = self.decodedPCMSampleRate;
    if (sampleRate <= 0 || self.sample.syntheticTerminal) return kCMTimeInvalid;
    if (self.sample.windowGeneration != self.track.windowGeneration) {
        int64_t value = useDecodeTimestamp ? self.sample.dts : self.sample.pts;
        if (value == AV_NOPTS_VALUE) value = useDecodeTimestamp ? self.sample.pts : self.sample.dts;
        CMTime packetTime = FMETime(value, self.track.timeScale);
        return CMTIME_IS_NUMERIC(packetTime)
            ? CMTimeAdd(packetTime, CMTimeMake(self.pcmFrameOffset, sampleRate))
            : packetTime;
    }
    FMESample *firstSample = self.track.decodeSamples.firstObject;
    if (!firstSample) return kCMTimeInvalid;
    int64_t anchorValue = useDecodeTimestamp ? firstSample.dts : firstSample.pts;
    if (anchorValue == AV_NOPTS_VALUE) {
        anchorValue = useDecodeTimestamp ? firstSample.pts : firstSample.dts;
    }
    CMTime anchorTime = FMETime(anchorValue, self.track.timeScale);
    if (!CMTIME_IS_NUMERIC(anchorTime)) return anchorTime;
    int64_t packetDistance = self.sample.decodeIndex - firstSample.decodeIndex;
    int64_t frameDistance = packetDistance * self.track.decodedPCMFramesPerPacket +
        self.pcmFrameOffset;
    return CMTimeAdd(anchorTime, CMTimeMake(frameDistance, sampleRate));
}

- (CMTime)presentationTimeStamp {
    if (self.track.decodesDTSToPCM) {
        CMTime continuousTime = [self continuousPCMTimeUsingDecodeTimestamp:NO];
        if (CMTIME_IS_NUMERIC(continuousTime)) return continuousTime;
    }
    int64_t value = self.sample.pts == AV_NOPTS_VALUE ? self.sample.dts : self.sample.pts;
    return FMETime(value, self.track.timeScale);
}

- (CMTime)decodeTimeStamp {
    if (self.track.decodesDTSToPCM) {
        CMTime continuousTime = [self continuousPCMTimeUsingDecodeTimestamp:YES];
        if (CMTIME_IS_NUMERIC(continuousTime)) return continuousTime;
    }
    return FMETime(self.sample.dts, self.track.timeScale);
}

- (CMTime)currentSampleDuration {
    int32_t sampleRate = self.decodedPCMSampleRate;
    if (sampleRate > 0) return CMTimeMake(1, sampleRate);
    return self.sample.duration > 0 ? CMTimeMake(self.sample.duration, self.track.timeScale) : kCMTimeIndefinite;
}

- (CMFormatDescriptionRef)currentSampleFormatDescription {
    return self.track.formatDescription;
}

- (void)stepInDecodeOrderByCount:(int64_t)stepCount
               completionHandler:(void (^)(int64_t, NSError *))completionHandler {
    NSError *syncError = nil;
    if (![self synchronizeWithCurrentWindowForDataAccess:&syncError]) {
        completionHandler(0, syncError);
        return;
    }
    if (self.usesPCMFrameGranularCursors && self.track.decodesDTSToPCM &&
        self.track.decodedPCMFramesPerPacket > 0) {
        int64_t framesPerPacket = self.track.decodedPCMFramesPerPacket;
        if (self.sample.syntheticTerminal) {
            NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
            if (stepCount < 0 && decodeSamples.count > 0) {
                self.sample = decodeSamples.lastObject;
                self.pcmFrameOffset = (UInt32)(framesPerPacket - 1);
                self.hasDeliveredCurrentSample = NO;
                completionHandler(-1, nil);
            } else {
                completionHandler(0, nil);
            }
            return;
        }

        int64_t oldIndex = self.sample.decodeIndex;
        int64_t oldOffset = self.pcmFrameOffset;
        int64_t combined = oldOffset + stepCount;
        int64_t packetDelta = combined >= 0
            ? combined / framesPerPacket
            : -((-combined + framesPerPacket - 1) / framesPerPacket);
        int64_t newOffset = combined - packetDelta * framesPerPacket;
        int64_t requestedIndex = oldIndex + packetDelta;
        BOOL hadDeliveredCurrentSample = self.hasDeliveredCurrentSample;
        if (stepCount > 0 && hadDeliveredCurrentSample) {
            NSError *indexError = nil;
            if (![self.track.asset ensureSampleForStream:self.track.streamIndex
                                           atDecodeIndex:requestedIndex + 1
                                                   error:&indexError] && indexError) {
                completionHandler(0, indexError);
                return;
            }
        }
        NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
        int64_t maximum = (int64_t)decodeSamples.count - 1;
        if (stepCount > 0 && !hadDeliveredCurrentSample && requestedIndex > maximum &&
            self.track.terminalSample) {
            self.sample = self.track.terminalSample;
            self.pcmFrameOffset = 0;
            self.hasDeliveredCurrentSample = NO;
            completionHandler(stepCount, nil);
            return;
        }
        int64_t newIndex = MIN(MAX(requestedIndex, 0), maximum);
        if (requestedIndex < 0) newOffset = 0;
        if (requestedIndex > maximum) newOffset = framesPerPacket - 1;
        self.sample = decodeSamples[(NSUInteger)newIndex];
        self.pcmFrameOffset = (UInt32)newOffset;
        self.hasDeliveredCurrentSample = NO;
        int64_t actualStep = (newIndex - oldIndex) * framesPerPacket + newOffset - oldOffset;
        [self.track.asset compactIndexedWindowsIfNeeded];
        completionHandler(actualStep, nil);
        return;
    }
    if (self.sample.syntheticTerminal) {
        NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
        if (stepCount < 0 && decodeSamples.count > 0) {
            self.sample = decodeSamples.lastObject;
            self.hasDeliveredCurrentSample = NO;
            completionHandler(-1, nil);
        } else {
            completionHandler(0, nil);
        }
        return;
    }
    int64_t oldIndex = self.sample.decodeIndex;
    BOOL hadDeliveredCurrentSample = self.hasDeliveredCurrentSample;
    if (stepCount > 0 && hadDeliveredCurrentSample) {
        // Keep one sample beyond the requested destination indexed.  If the
        // destination itself is the temporary end of our bounded window,
        // Core Media treats that boundary as end-of-track before loading it.
        // A single lookahead preserves lazy indexing without exposing the
        // window edge as EOF.
        NSError *indexError = nil;
        if (![self.track.asset ensureSampleForStream:self.track.streamIndex
                                       atDecodeIndex:oldIndex + stepCount + 1
                                               error:&indexError] && indexError) {
            completionHandler(0, indexError);
            return;
        }
    }
    NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
    int64_t maximum = (int64_t)decodeSamples.count - 1;
    int64_t newIndex = MIN(MAX(oldIndex + stepCount, 0), maximum);
    if (stepCount > 0 && !hadDeliveredCurrentSample && oldIndex + stepCount > maximum && self.track.terminalSample) {
        self.sample = self.track.terminalSample;
        self.hasDeliveredCurrentSample = NO;
        completionHandler(stepCount, nil);
        return;
    }
    self.sample = decodeSamples[(NSUInteger)newIndex];
    self.hasDeliveredCurrentSample = NO;
    [self.track.asset compactIndexedWindowsIfNeeded];
    completionHandler(newIndex - oldIndex, nil);
}

- (void)stepInPresentationOrderByCount:(int64_t)stepCount
                     completionHandler:(void (^)(int64_t, NSError *))completionHandler {
    NSError *syncError = nil;
    if (![self synchronizeWithCurrentWindowForDataAccess:&syncError]) {
        completionHandler(0, syncError);
        return;
    }
    if (self.usesPCMFrameGranularCursors && self.track.decodesDTSToPCM &&
        self.track.decodedPCMFramesPerPacket > 0) {
        int64_t framesPerPacket = self.track.decodedPCMFramesPerPacket;
        NSArray<FMESample *> *presentationSamples = self.track.presentationSamples;
        if (self.sample.syntheticTerminal) {
            if (stepCount < 0 && presentationSamples.count > 0) {
                self.sample = presentationSamples.lastObject;
                self.pcmFrameOffset = (UInt32)(framesPerPacket - 1);
                completionHandler(-1, nil);
            } else {
                completionHandler(0, nil);
            }
            return;
        }
        int64_t oldIndex = self.sample.presentationIndex;
        int64_t oldOffset = self.pcmFrameOffset;
        int64_t combined = oldOffset + stepCount;
        int64_t packetDelta = combined >= 0
            ? combined / framesPerPacket
            : -((-combined + framesPerPacket - 1) / framesPerPacket);
        int64_t newOffset = combined - packetDelta * framesPerPacket;
        int64_t requestedIndex = oldIndex + packetDelta;
        int64_t maximum = (int64_t)presentationSamples.count - 1;
        if (stepCount > 0 && requestedIndex > maximum && self.track.terminalSample) {
            self.sample = self.track.terminalSample;
            self.pcmFrameOffset = 0;
            completionHandler(stepCount, nil);
            return;
        }
        int64_t newIndex = MIN(MAX(requestedIndex, 0), maximum);
        if (requestedIndex < 0) newOffset = 0;
        if (requestedIndex > maximum) newOffset = framesPerPacket - 1;
        self.sample = presentationSamples[(NSUInteger)newIndex];
        self.pcmFrameOffset = (UInt32)newOffset;
        completionHandler((newIndex - oldIndex) * framesPerPacket + newOffset - oldOffset, nil);
        return;
    }
    NSArray<FMESample *> *presentationSamples = self.track.presentationSamples;
    if (self.sample.syntheticTerminal) {
        if (stepCount < 0 && presentationSamples.count > 0) {
            self.sample = presentationSamples.lastObject;
            completionHandler(-1, nil);
        } else {
            completionHandler(0, nil);
        }
        return;
    }
    int64_t oldIndex = self.sample.presentationIndex;
    // Keep presentation-order range discovery within the current window.
    // MediaToolbox uses this path to find boundaries; extending here would
    // make opening a file scan all the way to EOF. Decode-order playback is
    // still extended lazily by stepInDecodeOrderByCount:.
    int64_t maximum = (int64_t)presentationSamples.count - 1;
    int64_t newIndex = MIN(MAX(oldIndex + stepCount, 0), maximum);
    if (stepCount > 0 && oldIndex + stepCount > maximum && self.track.terminalSample) {
        self.sample = self.track.terminalSample;
        completionHandler(stepCount, nil);
        return;
    }
    self.sample = presentationSamples[(NSUInteger)newIndex];
    completionHandler(newIndex - oldIndex, nil);
}

- (FMESample *)sampleAtDecodeTime:(CMTime)time error:(NSError **)error {
    CMTime converted = CMTimeConvertScale(time, self.track.timeScale, kCMTimeRoundingMethod_Default);
    if (![self.track.asset ensureSamplesForStream:self.track.streamIndex
                      throughPresentationTimestamp:converted.value
                                              error:error]) return nil;
    NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
    if (decodeSamples.count == 0) {
        if (error) *error = FMEMediaError(MEErrorNoSamples, @"The track contains no decode samples.");
        return nil;
    }
    int64_t target = converted.value;
    NSInteger low = 0, high = (NSInteger)decodeSamples.count - 1, result = 0;
    while (low <= high) {
        NSInteger middle = low + (high - low) / 2;
        FMESample *candidate = decodeSamples[(NSUInteger)middle];
        int64_t value = candidate.dts == AV_NOPTS_VALUE ? candidate.pts : candidate.dts;
        if (value <= target) { result = middle; low = middle + 1; }
        else high = middle - 1;
    }
    return decodeSamples[(NSUInteger)result];
}

- (void)stepByDecodeTime:(CMTime)deltaDecodeTime
       completionHandler:(void (^)(CMTime, BOOL, NSError *))completionHandler {
    CMTime desired = CMTimeAdd(self.decodeTimeStamp, deltaDecodeTime);
    NSError *error = nil;
    FMESample *newSample = [self sampleAtDecodeTime:desired error:&error];
    if (!newSample) {
        completionHandler(kCMTimeInvalid, NO, error);
        return;
    }
    NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
    FMESample *first = decodeSamples.firstObject;
    FMESample *last = decodeSamples.lastObject;
    CMTime firstTime = FMETime(first.dts == AV_NOPTS_VALUE ? first.pts : first.dts, self.track.timeScale);
    CMTime lastTime = FMETime(last.dts == AV_NOPTS_VALUE ? last.pts : last.dts, self.track.timeScale);
    BOOL pinned = CMTimeCompare(desired, firstTime) < 0 || CMTimeCompare(desired, lastTime) > 0;
    self.sample = newSample;
    self.pcmFrameOffset = 0;
    self.hasDeliveredCurrentSample = NO;
    completionHandler(self.decodeTimeStamp, pinned, nil);
}

- (void)stepByPresentationTime:(CMTime)deltaPresentationTime
             completionHandler:(void (^)(CMTime, BOOL, NSError *))completionHandler {
    CMTime desired = CMTimeAdd(self.presentationTimeStamp, deltaPresentationTime);
    NSError *error = nil;
    FMESample *newSample = [self.track sampleAtPresentationTime:desired error:&error];
    if (!newSample) {
        completionHandler(kCMTimeInvalid, NO, error);
        return;
    }
    NSArray<FMESample *> *presentationSamples = self.track.presentationSamples;
    FMESample *first = presentationSamples.firstObject;
    FMESample *last = presentationSamples.lastObject;
    CMTime firstTime = FMETime(first.pts == AV_NOPTS_VALUE ? first.dts : first.pts, self.track.timeScale);
    CMTime lastTime = FMETime(last.pts == AV_NOPTS_VALUE ? last.dts : last.pts, self.track.timeScale);
    BOOL pinned = CMTimeCompare(desired, firstTime) < 0 || CMTimeCompare(desired, lastTime) > 0;
    self.sample = newSample;
    self.pcmFrameOffset = 0;
    self.hasDeliveredCurrentSample = NO;
    completionHandler(self.presentationTimeStamp, pinned, nil);
}

- (AVSampleCursorSyncInfo)syncInfo {
    [self synchronizeWithCurrentWindowForDataAccess:nil];
    BOOL key = (self.sample.flags & AV_PKT_FLAG_KEY) != 0;
    return (AVSampleCursorSyncInfo){
        .sampleIsFullSync = key,
        .sampleIsPartialSync = NO,
        .sampleIsDroppable = (self.sample.flags & AV_PKT_FLAG_DISCARD) != 0,
    };
}

- (AVSampleCursorDependencyInfo)dependencyInfo {
    [self synchronizeWithCurrentWindowForDataAccess:nil];
    BOOL key = (self.sample.flags & AV_PKT_FLAG_KEY) != 0;
    return (AVSampleCursorDependencyInfo){
        .sampleIndicatesWhetherItHasDependentSamples = NO,
        .sampleHasDependentSamples = NO,
        .sampleIndicatesWhetherItDependsOnOthers = YES,
        .sampleDependsOnOthers = !key,
        .sampleIndicatesWhetherItHasRedundantCoding = NO,
        .sampleHasRedundantCoding = NO,
    };
}

- (BOOL)samplesWithEarlierDTSsMayHaveLaterPTSsThanCursor:(id<MESampleCursor>)cursor {
    CMTime converted = CMTimeConvertScale(cursor.presentationTimeStamp,
                                          self.track.timeScale,
                                          kCMTimeRoundingMethod_Default);
    if (!CMTIME_IS_NUMERIC(converted)) return YES;
    FMESample *comparison = [FMESample new];
    comparison.pts = converted.value;
    comparison.dts = converted.value;
    return [self.track samplesEarlierThanSample:self.sample mayHavePTSAfterSample:comparison];
}

- (BOOL)samplesWithLaterDTSsMayHaveEarlierPTSsThanCursor:(id<MESampleCursor>)cursor {
    CMTime converted = CMTimeConvertScale(cursor.presentationTimeStamp,
                                          self.track.timeScale,
                                          kCMTimeRoundingMethod_Default);
    if (!CMTIME_IS_NUMERIC(converted)) return YES;
    FMESample *comparison = [FMESample new];
    comparison.pts = converted.value;
    comparison.dts = converted.value;
    return [self.track samplesLaterThanSample:self.sample mayHavePTSBeforeSample:comparison];
}

- (void)loadSampleBufferContainingSamplesToEndCursor:(id<MESampleCursor>)endSampleCursor
                                   completionHandler:(void (^)(CMSampleBufferRef, NSError *))completionHandler {
    NSError *syncError = nil;
    if (![self synchronizeWithCurrentWindowForDataAccess:&syncError]) {
        completionHandler(NULL, syncError);
        return;
    }
    if (self.sample.syntheticTerminal) {
        completionHandler(NULL, FMEMediaError(MEErrorNoSamples, @"The terminal cursor contains no media sample."));
        return;
    }
    if ([endSampleCursor isKindOfClass:[FMESampleCursor class]]) {
        FMESampleCursor *end = (FMESampleCursor *)endSampleCursor;
        if (end.track != self.track) {
            completionHandler(NULL, FMEMediaError(MEErrorNoSamples, @"The requested sample range crosses tracks."));
            return;
        }
        if (![end synchronizeWithCurrentWindowForDataAccess:&syncError]) {
            completionHandler(NULL, syncError);
            return;
        }
        if (self.sample.windowGeneration != self.track.windowGeneration ||
            end.sample.decodeIndex < self.sample.decodeIndex) {
            completionHandler(NULL, FMEMediaError(MEErrorNoSamples, @"The requested sample range is invalid."));
            return;
        }
    }

    if (self.track.decodesDTSToPCM) {
        const AudioStreamBasicDescription *asbd =
            CMAudioFormatDescriptionGetStreamBasicDescription(
                (CMAudioFormatDescriptionRef)self.track.formatDescription);
        if (!asbd || asbd->mBytesPerFrame == 0 || asbd->mSampleRate <= 0) {
            completionHandler(NULL, FMEError(41, @"The DTS PCM format description is invalid."));
            return;
        }

        NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
        NSInteger startPacketIndex = self.sample.decodeIndex;
        NSInteger endPacketIndex = startPacketIndex;
        UInt32 endFrameOffset = self.track.decodedPCMFramesPerPacket - 1;
        if ([endSampleCursor isKindOfClass:[FMESampleCursor class]]) {
            FMESampleCursor *end = (FMESampleCursor *)endSampleCursor;
            if (end.track == self.track && !end.sample.syntheticTerminal) {
                endPacketIndex = end.sample.decodeIndex;
                endFrameOffset = end.pcmFrameOffset;
            }
        }
        if (startPacketIndex < 0 || endPacketIndex < startPacketIndex ||
            endPacketIndex >= (NSInteger)decodeSamples.count ||
            (endPacketIndex == startPacketIndex && endFrameOffset < self.pcmFrameOffset)) {
            completionHandler(NULL, FMEError(42, @"The requested decoded PCM range is invalid."));
            return;
        }

        NSMutableData *rangePCMData = [NSMutableData data];
        CMItemCount outputFrameCount = 0;
        NSError *decodeError = nil;
        for (NSInteger packetIndex = startPacketIndex;
             packetIndex <= endPacketIndex; packetIndex++) {
            FMESample *packetSample = decodeSamples[(NSUInteger)packetIndex];
            CMItemCount packetFrameCount = 0;
            NSData *packetPCMData = [self.track.asset copyPCMDataForDecodedAudioSample:packetSample
                                                                            frameCount:&packetFrameCount
                                                                                 error:&decodeError];
            if (!packetPCMData || packetFrameCount <= 0 ||
                packetFrameCount != self.track.decodedPCMFramesPerPacket) {
                completionHandler(NULL, decodeError ?: FMEError(43, @"A decoded audio packet produced an invalid PCM frame count."));
                return;
            }
            CMItemCount firstFrame = packetIndex == startPacketIndex ? self.pcmFrameOffset : 0;
            CMItemCount frameEnd = packetFrameCount;
            if (packetIndex == endPacketIndex) {
                frameEnd = MIN(frameEnd, (CMItemCount)endFrameOffset + 1);
            }
            if (firstFrame >= frameEnd) {
                completionHandler(NULL, FMEError(44, @"The requested decoded PCM packet slice is empty."));
                return;
            }
            NSRange byteRange = NSMakeRange((NSUInteger)firstFrame * asbd->mBytesPerFrame,
                (NSUInteger)(frameEnd - firstFrame) * asbd->mBytesPerFrame);
            if (NSMaxRange(byteRange) > packetPCMData.length) {
                completionHandler(NULL, FMEError(45, @"The decoded PCM packet slice exceeds its data."));
                return;
            }
            [rangePCMData appendBytes:(const uint8_t *)packetPCMData.bytes + byteRange.location
                               length:byteRange.length];
            outputFrameCount += frameEnd - firstFrame;
        }
        NSData *pcmData = [rangePCMData copy];

        CMBlockBufferRef pcmBlockBuffer = NULL;
        OSStatus pcmStatus = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                                NULL,
                                                                pcmData.length,
                                                                kCFAllocatorDefault,
                                                                NULL,
                                                                0,
                                                                pcmData.length,
                                                                0,
                                                                &pcmBlockBuffer);
        if (pcmStatus == noErr) {
            pcmStatus = CMBlockBufferReplaceDataBytes(pcmData.bytes,
                                                      pcmBlockBuffer,
                                                      0,
                                                      pcmData.length);
        }
        if (pcmStatus != noErr) {
            if (pcmBlockBuffer) CFRelease(pcmBlockBuffer);
            completionHandler(NULL, FMEError(pcmStatus, @"Unable to create a DTS PCM block buffer."));
            return;
        }

        size_t byteOffset = 0;
        size_t outputByteCount = (size_t)outputFrameCount * asbd->mBytesPerFrame;
        int32_t sampleRate = (int32_t)llround(asbd->mSampleRate);
        CMSampleTimingInfo pcmTiming = {
            .duration = CMTimeMake(1, MAX(sampleRate, 1)),
            .presentationTimeStamp = self.presentationTimeStamp,
            .decodeTimeStamp = kCMTimeInvalid,
        };
        size_t pcmFrameSize = asbd->mBytesPerFrame;
        CMSampleBufferRef pcmSampleBuffer = NULL;
        if (byteOffset > 0 || outputByteCount < pcmData.length) {
            CMBlockBufferRef slicedBlockBuffer = NULL;
            pcmStatus = CMBlockBufferCreateContiguous(kCFAllocatorDefault,
                                                      pcmBlockBuffer,
                                                      kCFAllocatorDefault,
                                                      NULL,
                                                      byteOffset,
                                                      outputByteCount,
                                                      0,
                                                      &slicedBlockBuffer);
            CFRelease(pcmBlockBuffer);
            pcmBlockBuffer = slicedBlockBuffer;
        }
        if (pcmStatus != noErr) {
            if (pcmBlockBuffer) CFRelease(pcmBlockBuffer);
            completionHandler(NULL, FMEError(pcmStatus, @"Unable to slice a DTS PCM block buffer."));
            return;
        }
        pcmStatus = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                              pcmBlockBuffer,
                                              self.track.formatDescription,
                                              outputFrameCount,
                                              1,
                                              &pcmTiming,
                                              1,
                                              &pcmFrameSize,
                                              &pcmSampleBuffer);
        CFRelease(pcmBlockBuffer);
        if (pcmStatus != noErr) {
            completionHandler(NULL, FMEError(pcmStatus, @"Unable to create a DTS PCM sample buffer."));
            return;
        }

        self.hasDeliveredCurrentSample = YES;
        completionHandler(pcmSampleBuffer, nil);
        CFRelease(pcmSampleBuffer);
        return;
    }

    NSArray<FMESample *> *decodeSamples = self.track.decodeSamples;
    NSInteger startIndex = self.sample.decodeIndex;
    NSInteger endIndex = startIndex;
    if ([endSampleCursor isKindOfClass:[FMESampleCursor class]]) {
        FMESampleCursor *end = (FMESampleCursor *)endSampleCursor;
        if (!end.sample.syntheticTerminal) endIndex = end.sample.decodeIndex;
    }
    if (startIndex < 0 || endIndex < startIndex || endIndex >= (NSInteger)decodeSamples.count) {
        completionHandler(NULL, FMEMediaError(MEErrorNoSamples, @"The compressed sample range is unavailable."));
        return;
    }

    CMItemCount sampleCount = (CMItemCount)(endIndex - startIndex + 1);
    CMSampleTimingInfo *timings = calloc((size_t)sampleCount, sizeof(*timings));
    size_t *sampleSizes = calloc((size_t)sampleCount, sizeof(*sampleSizes));
    if (!timings || !sampleSizes) {
        free(timings);
        free(sampleSizes);
        completionHandler(NULL, FMEMediaError(MEErrorAllocationFailure, @"Unable to allocate compressed sample metadata."));
        return;
    }

    NSMutableData *rangeData = [NSMutableData data];
    NSError *error = nil;
    for (CMItemCount index = 0; index < sampleCount; index++) {
        FMESample *sample = decodeSamples[(NSUInteger)(startIndex + index)];
        NSData *data = [self.track.asset copyPacketDataForSample:sample error:&error];
        if (!data || rangeData.length > NSUIntegerMax - data.length) {
            free(timings);
            free(sampleSizes);
            completionHandler(NULL, error ?: FMEMediaError(MEErrorAllocationFailure, @"The compressed sample range is too large."));
            return;
        }
        [rangeData appendData:data];
        sampleSizes[index] = data.length;
        timings[index] = (CMSampleTimingInfo){
            .duration = sample.duration > 0
                ? CMTimeMake(sample.duration, self.track.timeScale) : kCMTimeIndefinite,
            .presentationTimeStamp = FMETime(sample.pts == AV_NOPTS_VALUE ? sample.dts : sample.pts,
                                             self.track.timeScale),
            .decodeTimeStamp = FMETime(sample.dts, self.track.timeScale),
        };
    }

    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         NULL,
                                                         rangeData.length,
                                                         kCFAllocatorDefault,
                                                         NULL,
                                                         0,
                                                         rangeData.length,
                                                         0,
                                                         &blockBuffer);
    if (status == noErr) {
        status = CMBlockBufferReplaceDataBytes(rangeData.bytes, blockBuffer, 0, rangeData.length);
    }
    if (status != noErr) {
        free(timings);
        free(sampleSizes);
        if (blockBuffer) CFRelease(blockBuffer);
        completionHandler(NULL, FMEError(status, @"Unable to create a Core Media block buffer."));
        return;
    }

    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                       blockBuffer,
                                       self.track.formatDescription,
                                       sampleCount,
                                       sampleCount,
                                       timings,
                                       sampleCount,
                                       sampleSizes,
                                       &sampleBuffer);
    free(timings);
    free(sampleSizes);
    CFRelease(blockBuffer);
    if (status != noErr) {
        completionHandler(NULL, FMEError(status, @"Unable to create a Core Media sample buffer."));
        return;
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
    if (attachments) {
        CFIndex attachmentCount = CFArrayGetCount(attachments);
        for (CMItemCount index = 0; index < sampleCount && index < attachmentCount; index++) {
            FMESample *sample = decodeSamples[(NSUInteger)(startIndex + index)];
            if ((sample.flags & AV_PKT_FLAG_KEY) == 0) {
                CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, index);
                CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
            }
        }
    }
    self.hasDeliveredCurrentSample = YES;
    completionHandler(sampleBuffer, nil);
    CFRelease(sampleBuffer);
}

@end
