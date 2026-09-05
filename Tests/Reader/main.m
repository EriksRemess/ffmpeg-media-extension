#import "FMEAsset.h"
#import "FMETrackReader.h"
#import "FMESampleCursor.h"
#include <libavformat/avformat.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

static void check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static FMESample *sampleAt(NSUInteger index, NSInteger stream) {
    FMESample *sample = [FMESample new];
    sample.streamIndex = stream;
    sample.decodeIndex = index;
    sample.pts = sample.dts = (int64_t)index * 40;
    sample.duration = 40;
    sample.filePosition = (int64_t)index + 100;
    sample.packetSize = 1;
    sample.flags = AV_PKT_FLAG_KEY;
    uint8_t byte = index % 251;
    sample.packetData = [NSData dataWithBytes:&byte length:1];
    return sample;
}

static FMETrackReader *makeTrack(FMEAsset *asset, NSInteger stream, NSUInteger count) {
    CMVideoFormatDescriptionRef format = NULL;
    check(CMVideoFormatDescriptionCreate(NULL, 'FVP9', 16, 16, NULL, &format) == noErr, @"video format");
    METrackInfo *info = [[METrackInfo alloc] initWithMediaType:kCMMediaType_Video trackID:(CMPersistentTrackID)stream + 1
        formatDescriptions:@[(__bridge id)format]];
    NSMutableArray *samples = [NSMutableArray array];
    for (NSUInteger index = 0; index < count; index++) [samples addObject:sampleAt(index, stream)];
    FMETrackReader *track = [[FMETrackReader alloc] initWithAsset:asset streamIndex:stream timeScale:1000
        formatDescription:format trackInfo:info decodesDTSToPCM:NO decodedPCMFramesPerPacket:0 samples:samples];
    CFRelease(format);
    return track;
}

@interface FMEAsset (TestIndexHooks)
- (BOOL)readAndAppendNextIndexedPacket:(NSError **)error;
- (void)trimIndexedWindowsIfNeededLocked;
@end

@interface FMEFormatReader : NSObject <MEFormatReader>
- (instancetype)initWithAsset:(FMEAsset *)asset;
@end

@interface SyntheticAsset : FMEAsset
@property(nonatomic) NSUInteger produced;
@property(nonatomic) NSUInteger total;
@property(nonatomic) NSUInteger peakWindow;
@property(nonatomic, copy) void (^onReadPayload)(void);
- (instancetype)initWithCount:(NSUInteger)count;
@end

@implementation SyntheticAsset
- (instancetype)initWithCount:(NSUInteger)count {
    if (!(self = [super init])) return nil;
    self.total = count;
    self.produced = MIN(count, 3);
    [self setValue:[NSValue valueWithCMTime:CMTimeMake((int64_t)count * 40, 1000)] forKey:@"duration"];
    [self setValue:[NSLock new] forKey:@"indexLock"];
    [self setValue:@(-1) forKey:@"indexProtectedStreamIndex"];
    FMETrackReader *active = makeTrack(self, 0, self.produced);
    FMETrackReader *ended = makeTrack(self, 1, 1);
    [self setValue:@[active, ended] forKey:@"tracks"];
    [self setValue:[@{@0: active, @1: ended} mutableCopy] forKey:@"tracksByStream"];
    return self;
}
- (BOOL)readAndAppendNextIndexedPacket:(NSError **)error {
    if (self.produced >= self.total) {
        [self setValue:@YES forKey:@"indexReachedEOF"];
        return NO;
    }
    [self.tracks[0] appendIndexedSample:sampleAt(self.produced++, 0)];
    [self.tracks[0] discardCachedPacketDataBeforeLastSampleCount:256];
    self.peakWindow = MAX(self.peakWindow, self.tracks[0].decodeSamples.count);
    return YES;
}
- (BOOL)ensureSamplesForStream:(NSInteger)stream throughPresentationTimestamp:(int64_t)timestamp error:(NSError **)error {
    @synchronized (self) {
        FMETrackReader *track = self.tracks[(NSUInteger)stream];
        FMESample *first = track.decodeSamples.firstObject;
        FMESample *last = track.decodeSamples.lastObject;
        if (!first || timestamp < first.pts || timestamp > last.pts + 30000) {
            for (FMETrackReader *entry in self.tracks) [entry resetIndexedSamplesAtPresentationTimestamp:timestamp];
            self.produced = (NSUInteger)MAX(timestamp / 40 - 4, 0);
            [self setValue:@NO forKey:@"indexReachedEOF"];
        }
        while (self.produced < self.total && (!track.decodeSamples.lastObject || track.decodeSamples.lastObject.pts < timestamp)) {
            [self readAndAppendNextIndexedPacket:error];
            [self trimIndexedWindowsIfNeededLocked];
        }
        return track.decodeSamples.count > 0;
    }
}
- (FMESample *)lastSampleForStream:(NSInteger)stream error:(NSError **)error {
    FMESample *sample = sampleAt(stream == 0 ? self.total - 1 : 0, stream);
    sample.windowGeneration = -1;
    return sample;
}
- (NSData *)copyPacketDataForSample:(FMESample *)sample error:(NSError **)error {
    if (self.onReadPayload) self.onReadPayload();
    return sampleAt((NSUInteger)(sample.pts / 40), sample.streamIndex).packetData;
}
@end

@interface SyntheticPCMAsset : SyntheticAsset
@end
@implementation SyntheticPCMAsset
- (instancetype)initWithCount:(NSUInteger)count {
    if (!(self = [super initWithCount:count])) return nil;
    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = 100;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 16;
    asbd.mBytesPerFrame = asbd.mBytesPerPacket = 4;
    CMAudioFormatDescriptionRef format = NULL;
    check(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &format) == noErr, @"PCM format");
    METrackInfo *info = [[METrackInfo alloc] initWithMediaType:kCMMediaType_Audio trackID:1
        formatDescriptions:@[(__bridge id)format]];
    FMETrackReader *track = [[FMETrackReader alloc] initWithAsset:self streamIndex:0 timeScale:1000
        formatDescription:format trackInfo:info decodesDTSToPCM:YES decodedPCMFramesPerPacket:4
        samples:self.tracks[0].decodeSamples];
    CFRelease(format);
    FMETrackReader *ended = self.tracks[1];
    [self setValue:@[track, ended] forKey:@"tracks"];
    [self setValue:[@{@0: track, @1: ended} mutableCopy] forKey:@"tracksByStream"];
    return self;
}
- (NSData *)copyPCMDataForDecodedAudioSample:(FMESample *)sample frameCount:(CMItemCount *)frameCount error:(NSError **)error {
    int16_t values[8];
    for (NSUInteger index = 0; index < 4; index++) {
        values[index * 2] = values[index * 2 + 1] = (int16_t)(sample.pts / 40 * 4 + index);
    }
    *frameCount = 4;
    return [NSData dataWithBytes:values length:sizeof(values)];
}
@end

static FMESampleCursor *firstCursor(FMETrackReader *track) {
    __block id<MESampleCursor> cursor = nil;
    [track generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:^(id<MESampleCursor> value, NSError *error) {
        check(value != nil && error == nil, @"first cursor");
        cursor = value;
    }];
    return (FMESampleCursor *)cursor;
}

static void step(FMESampleCursor *cursor, int64_t count, int64_t expected, BOOL presentation) {
    void (^completion)(int64_t, NSError *) = ^(int64_t actual, NSError *error) {
        check(error == nil, [NSString stringWithFormat:@"step failed: %@", error]);
        check(actual == expected, [NSString stringWithFormat:@"step %lld returned %lld, expected %lld", count, actual, expected]);
    };
    if (presentation) [cursor stepInPresentationOrderByCount:count completionHandler:completion];
    else [cursor stepInDecodeOrderByCount:count completionHandler:completion];
}

static void testOwnership(void) {
    __weak FMEAsset *weakAsset;
    __weak FMETrackReader *weakTrack;
    @autoreleasepool {
        SyntheticAsset *asset = [[SyntheticAsset alloc] initWithCount:10];
        weakAsset = asset;
        weakTrack = asset.tracks[0];
    }
    check(!weakAsset && !weakTrack, @"asset/track ownership cycle");
    FMESampleCursor *cursor;
    @autoreleasepool {
        SyntheticAsset *asset = [[SyntheticAsset alloc] initWithCount:10];
        weakAsset = asset;
        cursor = firstCursor(asset.tracks[0]);
    }
    check(weakAsset != nil, @"cursor must retain its asset");
    step(cursor, 5, 5, NO);
    cursor = nil;
    check(!weakAsset, @"cursor asset ownership must be released");

    __block id<METrackReader> exportedTrack;
    @autoreleasepool {
        SyntheticAsset *asset = [[SyntheticAsset alloc] initWithCount:10];
        weakAsset = asset;
        FMEFormatReader *reader = [[FMEFormatReader alloc] initWithAsset:asset];
        [reader loadTrackReadersWithCompletionHandler:^(NSArray<id<METrackReader>> *tracks, NSError *error) {
            check(tracks.count > 0 && !error, @"exported track lease");
            exportedTrack = tracks.firstObject;
        }];
    }
    check(weakAsset != nil, @"exported tracks must outlive their format reader safely");
    __block id<MESampleCursor> leasedCursor;
    @autoreleasepool {
        [exportedTrack generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:^(id<MESampleCursor> value, NSError *error) {
            check(value != nil && !error, @"cursor from a surviving exported track");
            leasedCursor = value;
        }];
        exportedTrack = nil;
    }
    check(weakAsset != nil, @"cursor retains the asset after its exported track is released");
    leasedCursor = nil;
    check(!weakAsset, @"exported track leases must not recreate the ownership cycle");
}

static void testIdentity(void) {
    SyntheticAsset *asset = [[SyntheticAsset alloc] initWithCount:10];
    FMETrackReader *track = asset.tracks[0];
    for (FMESample *sample in track.decodeSamples) sample.filePosition = 1234;
    FMESample *stale = sampleAt(2, 0);
    stale.filePosition = 1234;
    check([track sampleInCurrentWindowMatchingSample:stale].pts == stale.pts, @"laced sample identity");
    AVPacket *packet = av_packet_alloc();
    packet->stream_index = 0;
    packet->pos = 1234;
    packet->size = 1;
    packet->pts = 0;
    packet->dts = AV_NOPTS_VALUE;
    check(![stale matchesPacket:packet], @"wrong lace must not match");
    packet->pts = stale.pts;
    check([stale matchesPacket:packet], @"synthesized DTS must not prevent recovery");
    packet->pos++;
    check(![stale matchesPacket:packet], @"different file position must not match");
    packet->pos = -1;
    check([stale matchesPacket:packet], @"PTS fallback without a file position");
    av_packet_free(&packet);
}

static void testTraversalAndRanges(void) {
    for (NSNumber *order in @[@NO, @YES]) {
        SyntheticAsset *asset = [[SyntheticAsset alloc] initWithCount:12000];
        FMESampleCursor *cursor = firstCursor(asset.tracks[0]);
        step(cursor, 3, 3, order.boolValue);
        check(CMTimeCompare(cursor.presentationTimeStamp, CMTimeMake(120, 1000)) == 0, @"step beyond startup window");
        step(cursor, 8000, 8000, order.boolValue);
        check(CMTimeCompare(cursor.presentationTimeStamp, CMTimeMake(8003 * 40, 1000)) == 0, @"large bounded forward step");
        step(cursor, -4000, -4000, order.boolValue);
        check(CMTimeCompare(cursor.presentationTimeStamp, CMTimeMake(4003 * 40, 1000)) == 0, @"backward across compacted windows");
        step(cursor, INT64_MAX, 11999 - 4003, order.boolValue);
        step(cursor, 1, 0, order.boolValue);
        check(asset.peakWindow < 6200, @"active track indexing must remain bounded");
    }
    SyntheticAsset *asset = [[SyntheticAsset alloc] initWithCount:6000];
    FMESampleCursor *first = firstCursor(asset.tracks[0]);
    __block id<MESampleCursor> last;
    [asset.tracks[0] generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:^(id<MESampleCursor> value, NSError *error) {
        last = value;
        check(value != nil && !error, @"last sample cursor");
    }];
    [first loadSampleBufferContainingSamplesToEndCursor:last completionHandler:^(CMSampleBufferRef buffer, NSError *error) {
        check(buffer && !error, [NSString stringWithFormat:@"cross-window range: %@", error]);
        check(CMSampleBufferGetNumSamples(buffer) == 6000, @"range must include the actual last sample");
        uint8_t bytes[6000];
        check(CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(buffer), 0, sizeof(bytes), bytes) == noErr, @"range bytes");
        for (NSUInteger index = 0; index < sizeof(bytes); index++) check(bytes[index] == index % 251, @"range packet identity");
    }];
    step((FMESampleCursor *)last, -1, -1, NO);
    check(CMTimeCompare(last.presentationTimeStamp, CMTimeMake(5998 * 40, 1000)) == 0, @"last cursor negative step");
    [(FMESampleCursor *)last loadSampleBufferContainingSamplesToEndCursor:first completionHandler:^(CMSampleBufferRef buffer, NSError *error) {
        check(!buffer && [error.domain isEqual:MediaExtensionErrorDomain] && error.code == MEErrorNoSamples, @"reversed range error");
    }];
    SyntheticAsset *sparse = [[SyntheticAsset alloc] initWithCount:12000];
    NSError *error = nil;
    check(![sparse ensureSampleForStream:1 atDecodeIndex:1 error:&error] && !error, @"ended track EOF");
    check(sparse.peakWindow <= 4097 && sparse.tracks[0].decodeSamples.count <= 4096, @"unselected track must compact during an EOF scan");
}

static void testCompactionTransaction(void) {
    SyntheticAsset *asset = [[SyntheticAsset alloc] initWithCount:10];
    FMESampleCursor *cursor = firstCursor(asset.tracks[0]);
    step(cursor, 3, 3, NO);
    FMETrackReader *track = asset.tracks[0];
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t started = dispatch_semaphore_create(0);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    asset.onReadPayload = ^{
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            dispatch_semaphore_signal(started);
            [track trimIndexedSamplesToMaximumCount:4 retainingCount:3];
            dispatch_semaphore_signal(finished);
        });
        dispatch_semaphore_wait(started, DISPATCH_TIME_FOREVER);
        check(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0,
            @"compaction must wait for sample delivery");
    };
    [cursor loadSampleBufferContainingSamplesToEndCursor:nil completionHandler:^(CMSampleBufferRef buffer, NSError *error) {
        check(buffer && !error, @"serialized sample delivery");
        check(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffer), CMTimeMake(120, 1000)) == 0,
            @"compaction must not change the delivered packet");
    }];
    check(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, @"compaction transaction deadlock");
    asset.onReadPayload = nil;
}

static void testPCMRanges(void) {
    SyntheticPCMAsset *asset = [[SyntheticPCMAsset alloc] initWithCount:6000];
    FMESampleCursor *first = firstCursor(asset.tracks[0]);
    step(first, 3, 3, NO);
    __block id<MESampleCursor> last;
    [asset.tracks[0] generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:^(id<MESampleCursor> value, NSError *error) {
        check(value && !error, @"last PCM frame cursor");
        last = value;
    }];
    [first loadSampleBufferContainingSamplesToEndCursor:last completionHandler:^(CMSampleBufferRef buffer, NSError *error) {
        check(buffer && !error, [NSString stringWithFormat:@"PCM cross-window range: %@", error]);
        check(CMSampleBufferGetNumSamples(buffer) == 23997, @"full PCM range including final frame");
        check(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(buffer), CMTimeMake(3, 100)) == 0, @"PCM start frame timestamp");
        NSMutableData *data = [NSMutableData dataWithLength:23997 * 4];
        check(CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(buffer), 0, data.length, data.mutableBytes) == noErr, @"PCM bytes");
        const int16_t *values = data.bytes;
        for (NSUInteger index = 0; index < 23997 * 2; index++) {
            check(values[index] == (int16_t)(index / 2 + 3), @"PCM frame continuity across compaction");
        }
    }];
    step((FMESampleCursor *)last, -1, -1, NO);
    check(CMTimeCompare(last.presentationTimeStamp, CMTimeMake(23998, 100)) == 0, @"last PCM frame backward step");
}

// Test double for the byte-source selectors used by FMEAsset.
@interface FileByteSource : NSObject {
    int _fd;
    int64_t _length;
}
@property(nonatomic) BOOL failReads;
@property(nonatomic) uint64_t totalBytesRead;
@property(nonatomic) NSUInteger fileLengthQueries;
- (instancetype)initWithPath:(NSString *)path;
@end
@implementation FileByteSource
- (instancetype)initWithPath:(NSString *)path {
    if (!(self = [super init])) return nil;
    _fd = open(path.fileSystemRepresentation, O_RDONLY);
    struct stat info;
    if (_fd < 0 || fstat(_fd, &info) != 0) return nil;
    _length = info.st_size;
    return self;
}
- (int64_t)fileLength { self.fileLengthQueries++; return _length; }
- (NSString *)fileName { return @"regression-fixture.mkv"; }
- (BOOL)readDataOfLength:(size_t)length fromOffset:(int64_t)offset toDestination:(void *)destination
              bytesRead:(size_t *)bytesRead error:(NSError **)error {
    if (self.failReads || offset >= _length) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
        return NO;
    }
    ssize_t count = pread(_fd, destination, length, offset);
    if (count < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    *bytesRead = (size_t)count;
    self.totalBytesRead += (uint64_t)count;
    return YES;
}
- (void)dealloc { if (_fd >= 0) close(_fd); }
@end

static void testMedia(NSString *directory) {
    NSUInteger fixture = 0;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil]) {
        if (![@[@"mkv", @"webm"] containsObject:name.pathExtension.lowercaseString]) continue;
        @autoreleasepool {
            NSError *error = nil;
            FileByteSource *source = [[FileByteSource alloc] initWithPath:[directory stringByAppendingPathComponent:name]];
            FMEAsset *asset = [[FMEAsset alloc] initWithByteSource:(MEByteSource *)source error:&error];
            check(asset != nil, [NSString stringWithFormat:@"fixture %lu initialization: %@", fixture, error]);
            for (FMETrackReader *subtitle in asset.tracks) {
                if (CMFormatDescriptionGetMediaType(subtitle.formatDescription) != kCMMediaType_Subtitle) continue;
                check(subtitle.asset != asset, @"subtitles must own an independent index");
                NSMutableDictionary *generations = [NSMutableDictionary dictionary];
                for (FMETrackReader *avTrack in asset.tracks) {
                    if (avTrack.asset == asset) generations[@(avTrack.streamIndex)] = @(avTrack.windowGeneration);
                }
                NSUInteger lengthQueries = source.fileLengthQueries;
                FMESampleCursor *first = firstCursor(subtitle);
                check(source.fileLengthQueries == lengthQueries,
                    @"scanning to the first subtitle must not repeatedly query the remote file length");
                [first loadSampleBufferContainingSamplesToEndCursor:nil completionHandler:^(CMSampleBufferRef buffer, NSError *failure) {
                    check(buffer && !failure, @"initial timed-text sample");
                    size_t length = CMSampleBufferGetTotalSampleSize(buffer);
                    check(length >= 2, @"timed-text length prefix");
                    uint8_t prefix[2];
                    check(CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(buffer), 0, 2, prefix) == noErr,
                        @"read timed-text prefix");
                    check((((size_t)prefix[0] << 8) | prefix[1]) == length - 2, @"timed-text payload length");
                }];
                uint64_t before = source.totalBytesRead;
                for (NSUInteger repetition = 0; repetition < 3; repetition++) (void)firstCursor(subtitle);
                check(source.totalBytesRead == before, @"repeated subtitle startup must not rescan media");
                for (FMETrackReader *avTrack in asset.tracks) {
                    if (avTrack.asset == asset) check(avTrack.windowGeneration == [generations[@(avTrack.streamIndex)] integerValue],
                        @"subtitle discovery must not compact or reset audio/video windows");
                }
                // Conversely, an A/V distant seek must not invalidate subtitle cursors.
                NSInteger subtitleGeneration = subtitle.windowGeneration;
                FMETrackReader *avTrack = asset.tracks.firstObject;
                [avTrack generateSampleCursorAtPresentationTimeStamp:CMTimeMake(180, 1)
                    completionHandler:^(id<MESampleCursor> value, NSError *failure) {
                        check(value && !failure, @"A/V seek with subtitle cursor retained");
                    }];
                check(subtitle.windowGeneration == subtitleGeneration, @"A/V seeks must not reset subtitle windows");
                // A video cue can fall inside a subtitle. Recover the cue's
                // original start instead of returning the following subtitle.
                FMESample *initial = [first valueForKey:@"sample"];
                FMESample *terminal = [subtitle.asset lastSampleForStream:subtitle.streamIndex error:&error];
                check(terminal && !error, @"subtitle tail discovery");
                for (FMESample *expected in @[terminal, initial, terminal]) {
                    if (expected.duration <= 1) continue;
                    CMTime inside = CMTimeMake(expected.pts + MIN(expected.duration / 2, subtitle.timeScale), subtitle.timeScale);
                    FMESample *found = [subtitle sampleAtPresentationTime:inside error:&error];
                    check(found && !error && found.pts <= inside.value,
                        @"subtitle seek must find a preceding cue rather than a future cue");
                    if (expected == terminal) check([found matchesSample:terminal], @"seek inside the final subtitle");
                }
            }
            for (FMETrackReader *track in asset.tracks) {
                printf("Direct fixture %lu stream %ld startup.\n", fixture, (long)track.streamIndex);
                FMESampleCursor *cursor = firstCursor(track);
                step(cursor, 3, 3, NO);
                [cursor loadSampleBufferContainingSamplesToEndCursor:nil completionHandler:^(CMSampleBufferRef buffer, NSError *failure) {
                    check(buffer && !failure, [NSString stringWithFormat:@"fixture %lu initial data: %@", fixture, failure]);
                }];
                __block id<MESampleCursor> last;
                [track generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:^(id<MESampleCursor> value, NSError *failure) {
                    check(value && !failure, [NSString stringWithFormat:@"fixture %lu tail: %@", fixture, failure]);
                    last = value;
                }];
                printf("Direct fixture %lu stream %ld tail %.3f.\n", fixture, (long)track.streamIndex, CMTimeGetSeconds(last.presentationTimeStamp));
                step((FMESampleCursor *)last, -1, -1, NO);
                [last loadSampleBufferContainingSamplesToEndCursor:nil completionHandler:^(CMSampleBufferRef buffer, NSError *failure) {
                    check(buffer && !failure, [NSString stringWithFormat:@"fixture %lu tail data: %@", fixture, failure]);
                }];
                // Force payload recovery in a fresh demuxer. Audio-only seeks
                // can scan an entire large movie when its cues index video.
                if (track.decodesDTSToPCM) {
                    FMESample *sample = [(FMESampleCursor *)last valueForKey:@"sample"];
                    sample.packetData = nil;
                    uint64_t before = source.totalBytesRead;
                    NSData *recovered = [asset copyPacketDataForSample:sample error:&error];
                    check(recovered.length == (NSUInteger)sample.packetSize && !error, @"recover evicted tail audio");
                    uint64_t readBytes = source.totalBytesRead - before;
                    printf("Tail audio recovery read %llu bytes.\n", (unsigned long long)readBytes);
                    if (source.fileLength > 1024LL * 1024 * 1024) {
                        check(readBytes < (uint64_t)source.fileLength / 4, @"tail audio recovery must use cues instead of scanning the movie");
                    }
                }
                [cursor loadSampleBufferContainingSamplesToEndCursor:nil completionHandler:^(CMSampleBufferRef buffer, NSError *failure) {
                    check(buffer && !failure, [NSString stringWithFormat:@"fixture %lu stale startup cursor: %@", fixture, failure]);
                }];
            }
            FileByteSource *failingSource = [[FileByteSource alloc] initWithPath:[directory stringByAppendingPathComponent:name]];
            failingSource.failReads = YES;
            NSError *readError = nil;
            FMEAsset *unreadable = [[FMEAsset alloc] initWithByteSource:(MEByteSource *)failingSource error:&readError];
            check(!unreadable && [readError.domain isEqual:NSPOSIXErrorDomain] && readError.code == EIO,
                @"a failed read before EOF must preserve its I/O error");
            printf("Direct reader fixture %lu passed.\n", ++fixture);
        }
    }
    check(fixture > 0, @"no direct-reader fixtures");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        setbuf(stdout, NULL);
        testOwnership();
        testIdentity();
        testTraversalAndRanges();
        testCompactionTransaction();
        testPCMRanges();
        puts("Synthetic reader regressions passed.");
        if (argc > 1) testMedia(@(argv[1]));
    }
    return 0;
}
