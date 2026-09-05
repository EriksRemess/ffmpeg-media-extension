#import "FMESampleCursor.h"

#include <libavformat/avformat.h>

@interface FMESampleCursor ()
@property(nonatomic) FMETrackReader *track;
@property(nonatomic) FMEAsset *asset;
@property(nonatomic) FMESample *sample;
@property(nonatomic) UInt32 pcmFrameOffset;
@end

@implementation FMESampleCursor

- (BOOL)synchronizeWithCurrentWindowForDataAccess:(NSError **)error {
    @synchronized (self.asset) {
    if ([self.track isSampleInCurrentWindow:self.sample]) return YES;
    FMESample *replacement = [self.track sampleInCurrentWindowMatchingSample:self.sample];
    if (replacement) {
        self.sample = replacement;
        return YES;
    }

    int64_t value = self.sample.pts == AV_NOPTS_VALUE ? self.sample.dts : self.sample.pts;
    if (value == AV_NOPTS_VALUE) {
        if (error) *error = FMEMediaError(MEErrorNoSamples, @"A stale cursor has no presentation timestamp.");
        return NO;
    }
    // Audio packets immediately before a video cue can have later timestamps
    // than that cue. Include preroll when recovering an exact stale packet.
    int64_t preroll = MAX(value - (int64_t)self.track.timeScale * 2, 0);
    if (![self.asset ensureSamplesForStream:self.track.streamIndex
                      throughPresentationTimestamp:preroll
                                              error:error]) return NO;
    if (![self.asset ensureSamplesForStream:self.track.streamIndex
                      throughPresentationTimestamp:value
                                              error:error]) return NO;
    replacement = [self.track sampleInCurrentWindowMatchingSample:self.sample];
    if (!replacement) {
        // A reordered frame can follow a reference frame whose PTS already
        // covers the target. Finish the small decode-order lookahead before
        // deciding that this exact packet is absent.
        NSError *indexError = nil;
        [self.asset ensureSampleForStream:self.track.streamIndex
                            atDecodeIndex:(NSInteger)self.track.decodeSamples.count + 32
                                    error:&indexError];
        if (indexError) {
            if (error) *error = indexError;
            return NO;
        }
        replacement = [self.track sampleInCurrentWindowMatchingSample:self.sample];
    }
    if (!replacement) {
        if (error) *error = FMEMediaError(MEErrorNoSamples, [NSString stringWithFormat:
            @"The cursor packet at position %lld (PTS %lld, stream %ld) is not in the recovered window (%lld through %lld).",
            self.sample.filePosition, self.sample.pts, (long)self.track.streamIndex,
            self.track.decodeSamples.firstObject.pts, self.track.decodeSamples.lastObject.pts]);
        return NO;
    }
    self.sample = replacement;
    return YES;
    }
}

- (instancetype)initWithTrack:(FMETrackReader *)track sample:(FMESample *)sample {
    return [self initWithTrack:track sample:sample pcmFrameOffset:0];
}

- (instancetype)initWithTrack:(FMETrackReader *)track sample:(FMESample *)sample pcmFrameOffset:(UInt32)offset {
    if ((self = [super init])) {
        _track = track;
        _asset = track.asset;
        _sample = sample;
        _pcmFrameOffset = offset;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    @synchronized (self.asset) {
    FMESampleCursor *copy = [[[self class] allocWithZone:zone] initWithTrack:self.track sample:self.sample];
    copy.pcmFrameOffset = self.pcmFrameOffset;
    return copy;
    }
}

- (int32_t)decodedPCMSampleRate {
    @synchronized (self.asset) {
    if (!self.track.decodesDTSToPCM) return 0;
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(
            (CMAudioFormatDescriptionRef)self.track.formatDescription);
    return asbd ? (int32_t)llround(asbd->mSampleRate) : 0;
    }
}

- (CMTime)continuousPCMTimeUsingDecodeTimestamp:(BOOL)useDecodeTimestamp {
    @synchronized (self.asset) {
    int32_t sampleRate = self.decodedPCMSampleRate;
    if (sampleRate <= 0) return kCMTimeInvalid;
    if (![self.track isSampleInCurrentWindow:self.sample]) {
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
}

- (CMTime)presentationTimeStamp {
    @synchronized (self.asset) {
    if (self.track.decodesDTSToPCM) {
        CMTime continuousTime = [self continuousPCMTimeUsingDecodeTimestamp:NO];
        if (CMTIME_IS_NUMERIC(continuousTime)) return continuousTime;
    }
    int64_t value = self.sample.pts == AV_NOPTS_VALUE ? self.sample.dts : self.sample.pts;
    return FMETime(value, self.track.timeScale);
    }
}

- (CMTime)decodeTimeStamp {
    @synchronized (self.asset) {
    if (self.track.decodesDTSToPCM) {
        CMTime continuousTime = [self continuousPCMTimeUsingDecodeTimestamp:YES];
        if (CMTIME_IS_NUMERIC(continuousTime)) return continuousTime;
    }
    return FMETime(self.sample.dts, self.track.timeScale);
    }
}

- (CMTime)currentSampleDuration {
    @synchronized (self.asset) {
    int32_t sampleRate = self.decodedPCMSampleRate;
    if (sampleRate > 0) return CMTimeMake(1, sampleRate);
    return self.sample.duration > 0
        ? CMTimeMake(self.sample.duration, self.track.timeScale) : kCMTimeIndefinite;
    }
}

- (CMFormatDescriptionRef)currentSampleFormatDescription {
    @synchronized (self.asset) {
    return self.track.formatDescription;
    }
}

- (void)stepByCount:(int64_t)stepCount
  presentationOrder:(BOOL)presentationOrder
  completionHandler:(void (^)(int64_t, NSError *))completionHandler {
    @synchronized (self.asset) {
    NSError *error = nil;
    if (![self synchronizeWithCurrentWindowForDataAccess:&error]) {
        completionHandler(0, error);
        return;
    }
    int64_t framesPerPacket = self.track.decodesDTSToPCM
        ? MAX(self.track.decodedPCMFramesPerPacket, 1) : 1;
    int64_t remaining = stepCount;
    int64_t moved = 0;
    while (remaining != 0) {
        @autoreleasepool {
            if (![self synchronizeWithCurrentWindowForDataAccess:&error]) break;
            NSInteger index = presentationOrder ? self.sample.presentationIndex : self.sample.decodeIndex;
            if (remaining < 0 && index == 0 && self.pcmFrameOffset == 0 &&
                !self.track.currentWindowStartsAtBeginning) {
                if (![self.asset extendWindowBeforeSample:self.sample error:&error] ||
                    ![self synchronizeWithCurrentWindowForDataAccess:&error]) break;
                index = presentationOrder ? self.sample.presentationIndex : self.sample.decodeIndex;
                if (index == 0 && !self.track.currentWindowStartsAtBeginning) {
                    error = FMEMediaError(MEErrorNoSamples, @"Unable to recover the preceding sample window.");
                    break;
                }
            }
            // Keep each extension bounded even for an arbitrarily large count.
            // A cursor's movement must not depend on whether it has loaded data.
            int64_t chunk = MIN(MAX(remaining, -1024 * framesPerPacket), 1024 * framesPerPacket);
            if (chunk > 0) {
                NSArray<FMESample *> *decode = self.track.decodeSamples;
                NSInteger lookahead = presentationOrder &&
                    CMFormatDescriptionGetMediaType(self.track.formatDescription) == kCMMediaType_Video ? 32 : 1;
                int64_t targetPacket = index + (self.pcmFrameOffset + chunk) / framesPerPacket;
                if (targetPacket + lookahead >= (int64_t)decode.count) {
                    NSInteger requested = presentationOrder
                        ? (NSInteger)decode.count + MIN((NSInteger)(chunk / framesPerPacket), 1024) + lookahead
                        : (NSInteger)targetPacket + lookahead;
                    if (![self.asset ensureSampleForStream:self.track.streamIndex
                                             atDecodeIndex:requested error:&error] && error) break;
                }
            }
            NSArray<FMESample *> *samples = presentationOrder
                ? self.track.presentationSamples : self.track.decodeSamples;
            if (samples.count == 0) {
                error = FMEMediaError(MEErrorNoSamples, @"The track contains no samples.");
                break;
            }
            // Appending reordered frames can change presentation indices.
            index = presentationOrder ? self.sample.presentationIndex : self.sample.decodeIndex;
            int64_t oldFrame = (int64_t)index * framesPerPacket + self.pcmFrameOffset;
            int64_t maximum = (int64_t)samples.count * framesPerPacket - 1;
            int64_t nextFrame = MIN(MAX(oldFrame + chunk, 0), maximum);
            int64_t actual = nextFrame - oldFrame;
            if (actual == 0) break;
            self.sample = samples[(NSUInteger)(nextFrame / framesPerPacket)];
            self.pcmFrameOffset = (UInt32)(nextFrame % framesPerPacket);
            moved += actual;
            remaining -= actual;
            [self.asset compactIndexedWindowsIfNeeded];
        }
    }
    completionHandler(moved, error);
    }
}

- (void)stepInDecodeOrderByCount:(int64_t)stepCount
             completionHandler:(void (^)(int64_t, NSError *))completionHandler {
    @synchronized (self.asset) {
    [self stepByCount:stepCount presentationOrder:NO completionHandler:completionHandler];
    }
}

- (void)stepInPresentationOrderByCount:(int64_t)stepCount
                   completionHandler:(void (^)(int64_t, NSError *))completionHandler {
    @synchronized (self.asset) {
    [self stepByCount:stepCount presentationOrder:YES completionHandler:completionHandler];
    }
}

- (FMESample *)sampleAtDecodeTime:(CMTime)time error:(NSError **)error {
    @synchronized (self.asset) {
    CMTime converted = CMTimeConvertScale(time, self.track.timeScale, kCMTimeRoundingMethod_Default);
    if (!CMTIME_IS_NUMERIC(converted)) {
        if (error) *error = FMEMediaError(MEErrorInvalidParameter, @"The requested decode timestamp is invalid.");
        return nil;
    }
    if (![self.asset ensureSamplesForStream:self.track.streamIndex
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
}

- (void)stepByDecodeTime:(CMTime)deltaDecodeTime
       completionHandler:(void (^)(CMTime, BOOL, NSError *))completionHandler {
    @synchronized (self.asset) {
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
    completionHandler(self.decodeTimeStamp, pinned, nil);
    }
}

- (void)stepByPresentationTime:(CMTime)deltaPresentationTime
             completionHandler:(void (^)(CMTime, BOOL, NSError *))completionHandler {
    @synchronized (self.asset) {
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
    completionHandler(self.presentationTimeStamp, pinned, nil);
    }
}

- (AVSampleCursorSyncInfo)syncInfo {
    @synchronized (self.asset) {
    [self synchronizeWithCurrentWindowForDataAccess:nil];
    BOOL key = (self.sample.flags & AV_PKT_FLAG_KEY) != 0;
    return (AVSampleCursorSyncInfo){
        .sampleIsFullSync = key,
        .sampleIsPartialSync = NO,
        .sampleIsDroppable = (self.sample.flags & AV_PKT_FLAG_DISCARD) != 0,
    };
    }
}

- (AVSampleCursorDependencyInfo)dependencyInfo {
    @synchronized (self.asset) {
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
}

- (BOOL)samplesWithEarlierDTSsMayHaveLaterPTSsThanCursor:(id<MESampleCursor>)cursor {
    @synchronized (self.asset) {
    CMTime converted = CMTimeConvertScale(cursor.presentationTimeStamp,
                                          self.track.timeScale,
                                          kCMTimeRoundingMethod_Default);
    if (!CMTIME_IS_NUMERIC(converted)) return YES;
    FMESample *comparison = [FMESample new];
    comparison.pts = converted.value;
    comparison.dts = converted.value;
    return [self.track samplesEarlierThanSample:self.sample mayHavePTSAfterSample:comparison];
    }
}

- (BOOL)samplesWithLaterDTSsMayHaveEarlierPTSsThanCursor:(id<MESampleCursor>)cursor {
    @synchronized (self.asset) {
    CMTime converted = CMTimeConvertScale(cursor.presentationTimeStamp,
                                          self.track.timeScale,
                                          kCMTimeRoundingMethod_Default);
    if (!CMTIME_IS_NUMERIC(converted)) return YES;
    FMESample *comparison = [FMESample new];
    comparison.pts = converted.value;
    comparison.dts = converted.value;
    return [self.track samplesLaterThanSample:self.sample mayHavePTSBeforeSample:comparison];
    }
}

- (void)loadSampleBufferContainingSamplesToEndCursor:(id<MESampleCursor>)endSampleCursor
                                 completionHandler:(void (^)(CMSampleBufferRef, NSError *))completionHandler {
    @synchronized (self.asset) {
    NSError *error = nil;
    if (![self synchronizeWithCurrentWindowForDataAccess:&error]) {
        completionHandler(NULL, error);
        return;
    }
    FMESampleCursor *end = nil;
    if (endSampleCursor) {
        if (![endSampleCursor isKindOfClass:[FMESampleCursor class]] ||
            ((FMESampleCursor *)endSampleCursor).track != self.track) {
            completionHandler(NULL, FMEMediaError(MEErrorNoSamples, @"The requested sample range crosses tracks."));
            return;
        }
        end = (FMESampleCursor *)endSampleCursor;
    }
    FMESample *endSample = end ? end.sample : self.sample;
    UInt32 endOffset = end ? end.pcmFrameOffset : self.pcmFrameOffset;
    BOOL samePacket = [self.sample matchesSample:endSample];
    BOOL endBeforeStart = samePacket && endOffset < self.pcmFrameOffset;
    if (!samePacket) {
        if (self.sample.filePosition >= 0 && endSample.filePosition >= 0) {
            endBeforeStart = endSample.filePosition < self.sample.filePosition;
            if (endSample.filePosition == self.sample.filePosition &&
                self.sample.pts != AV_NOPTS_VALUE && endSample.pts != AV_NOPTS_VALUE) {
                endBeforeStart = endSample.pts < self.sample.pts;
            }
        } else if ([self.track isSampleInCurrentWindow:endSample]) {
            endBeforeStart = endSample.decodeIndex < self.sample.decodeIndex;
        } else if (self.sample.dts != AV_NOPTS_VALUE && endSample.dts != AV_NOPTS_VALUE) {
            endBeforeStart = endSample.dts < self.sample.dts;
        }
    }
    if (endBeforeStart) {
        completionHandler(NULL, FMEMediaError(MEErrorNoSamples, @"The requested sample range ends before its start."));
        return;
    }

    BOOL pcm = self.track.decodesDTSToPCM;
    const AudioStreamBasicDescription *asbd = pcm
        ? CMAudioFormatDescriptionGetStreamBasicDescription((CMAudioFormatDescriptionRef)self.track.formatDescription) : NULL;
    if (pcm && (!asbd || asbd->mBytesPerFrame == 0 || asbd->mSampleRate <= 0)) {
        completionHandler(NULL, FMEError(41, @"The PCM format description is invalid."));
        return;
    }
    CMTime startTime = self.presentationTimeStamp;
    FMESampleCursor *walk = [self copy];
    NSMutableData *rangeData = [NSMutableData data];
    NSMutableData *timingData = [NSMutableData data];
    NSMutableData *sizeData = [NSMutableData data];
    NSMutableIndexSet *nonSyncSamples = [NSMutableIndexSet indexSet];
    CMItemCount sampleCount = 0;
    BOOL firstPacket = YES;
    while (YES) {
        @autoreleasepool {
            FMESample *sample = walk.sample;
            BOOL lastPacket = [sample matchesSample:endSample];
            NSData *data = nil;
            if (pcm) {
                CMItemCount packetFrames = 0;
                data = [self.asset copyPCMDataForDecodedAudioSample:sample frameCount:&packetFrames error:&error];
                if (!data || packetFrames <= 0 || packetFrames != self.track.decodedPCMFramesPerPacket) {
                    error = error ?: FMEError(43, @"A decoded audio packet produced an invalid PCM frame count.");
                    break;
                }
                CMItemCount firstFrame = firstPacket ? self.pcmFrameOffset : 0;
                CMItemCount frameEnd = lastPacket ? (CMItemCount)endOffset + 1 : packetFrames;
                if (firstFrame >= frameEnd || frameEnd > packetFrames ||
                    (NSUInteger)frameEnd > data.length / asbd->mBytesPerFrame) {
                    error = FMEMediaError(MEErrorNoSamples, @"The requested PCM slice is invalid.");
                    break;
                }
                NSUInteger byteCount = (NSUInteger)(frameEnd - firstFrame) * asbd->mBytesPerFrame;
                if (rangeData.length > NSUIntegerMax - byteCount || sampleCount > LONG_MAX - (frameEnd - firstFrame)) {
                    error = FMEMediaError(MEErrorAllocationFailure, @"The PCM range is too large.");
                    break;
                }
                [rangeData appendBytes:(const uint8_t *)data.bytes + (NSUInteger)firstFrame * asbd->mBytesPerFrame length:byteCount];
                sampleCount += frameEnd - firstFrame;
            } else {
                data = [self.asset copyPacketDataForSample:sample error:&error];
                if (!data || rangeData.length > NSUIntegerMax - data.length || sampleCount == LONG_MAX) {
                    error = error ?: FMEMediaError(MEErrorAllocationFailure, @"The compressed sample range is too large.");
                    break;
                }
                [rangeData appendData:data];
                size_t size = data.length;
                [sizeData appendBytes:&size length:sizeof(size)];
                CMSampleTimingInfo timing = {
                    .duration = sample.duration > 0 ? CMTimeMake(sample.duration, self.track.timeScale) : kCMTimeIndefinite,
                    .presentationTimeStamp = FMETime(sample.pts == AV_NOPTS_VALUE ? sample.dts : sample.pts, self.track.timeScale),
                    .decodeTimeStamp = FMETime(sample.dts, self.track.timeScale),
                };
                [timingData appendBytes:&timing length:sizeof(timing)];
                if (!(sample.flags & AV_PKT_FLAG_KEY)) [nonSyncSamples addIndex:(NSUInteger)sampleCount];
                sampleCount++;
            }
            if (lastPacket) break;
            firstPacket = NO;
            // Consume each packet before extending/compacting its index. The
            // range may span many windows, and its end cursor must not seek
            // the shared index away from the start of the range.
            walk.pcmFrameOffset = 0;
            int64_t packetStep = pcm ? self.track.decodedPCMFramesPerPacket : 1;
            __block int64_t actual = 0;
            __block NSError *stepError = nil;
            [walk stepInDecodeOrderByCount:packetStep completionHandler:^(int64_t count, NSError *failure) {
                actual = count;
                stepError = failure;
            }];
            if (stepError || actual != packetStep) {
                error = stepError ?: FMEMediaError(MEErrorNoSamples, @"The requested range endpoint is unavailable.");
                break;
            }
        }
    }
    if (error) {
        completionHandler(NULL, error);
        return;
    }

    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, rangeData.length,
        kCFAllocatorDefault, NULL, 0, rangeData.length, 0, &block);
    if (status == noErr) status = CMBlockBufferReplaceDataBytes(rangeData.bytes, block, 0, rangeData.length);
    if (status != noErr) {
        if (block) CFRelease(block);
        completionHandler(NULL, FMEError(status, @"Unable to create a Core Media block buffer."));
        return;
    }
    CMSampleTimingInfo pcmTiming = {
        .duration = pcm ? CMTimeMake(1, (int32_t)llround(asbd->mSampleRate)) : kCMTimeInvalid,
        .presentationTimeStamp = startTime,
        .decodeTimeStamp = kCMTimeInvalid,
    };
    size_t pcmSize = pcm ? asbd->mBytesPerFrame : 0;
    CMSampleBufferRef buffer = NULL;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, self.track.formatDescription,
        sampleCount, pcm ? 1 : sampleCount,
        pcm ? &pcmTiming : (const CMSampleTimingInfo *)timingData.bytes,
        pcm ? 1 : sampleCount, pcm ? &pcmSize : (const size_t *)sizeData.bytes, &buffer);
    CFRelease(block);
    if (status != noErr) {
        completionHandler(NULL, FMEError(status, @"Unable to create a Core Media sample buffer."));
        return;
    }
    if (!pcm && nonSyncSamples.count > 0) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, true);
        if (attachments) {
            [nonSyncSamples enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
                if (index < (NSUInteger)CFArrayGetCount(attachments)) {
                    CFMutableDictionaryRef attachment = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, (CFIndex)index);
                    CFDictionarySetValue(attachment, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
                }
            }];
        }
    }
    completionHandler(buffer, nil);
    CFRelease(buffer);
    }
}

@end
