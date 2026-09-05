#import "FMEAsset.h"
#import "FMETrackReader.h"

NSErrorDomain const FMEErrorDomain = @"lv.apps.ffmpeg-media-extension";

@interface FMEFormatReaderFactory : NSObject <MEFormatReaderExtension>
@end

// Media Toolbox can retain a track after releasing its format reader. Export
// a lease that owns the asset, while the asset's internal track has a weak
// back-reference. This preserves that lifetime without an asset/track cycle.
@interface FMETrackReaderLease : NSObject <METrackReader>
@property(nonatomic) FMEAsset *asset;
@property(nonatomic) FMETrackReader *track;
@end

@implementation FMETrackReaderLease
- (void)loadTrackInfoWithCompletionHandler:(void (^)(METrackInfo *, NSError *))completionHandler {
    [self.track loadTrackInfoWithCompletionHandler:completionHandler];
}
- (void)generateSampleCursorAtPresentationTimeStamp:(CMTime)time
                                completionHandler:(void (^)(id<MESampleCursor>, NSError *))completionHandler {
    [self.track generateSampleCursorAtPresentationTimeStamp:time completionHandler:completionHandler];
}
- (void)generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:(void (^)(id<MESampleCursor>, NSError *))completionHandler {
    [self.track generateSampleCursorAtFirstSampleInDecodeOrderWithCompletionHandler:completionHandler];
}
- (void)generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:(void (^)(id<MESampleCursor>, NSError *))completionHandler {
    [self.track generateSampleCursorAtLastSampleInDecodeOrderWithCompletionHandler:completionHandler];
}
- (void)loadUneditedDurationWithCompletionHandler:(void (^)(CMTime, NSError *))completionHandler {
    [self.track loadUneditedDurationWithCompletionHandler:completionHandler];
}
- (void)loadMetadataWithCompletionHandler:(void (^)(NSArray<AVMetadataItem *> *, NSError *))completionHandler {
    [self.track loadMetadataWithCompletionHandler:completionHandler];
}
@end

@interface FMEFormatReader : NSObject <MEFormatReader>
@property(nonatomic, readonly) FMEAsset *asset;
- (instancetype)initWithAsset:(FMEAsset *)asset;
@end


@implementation FMEFormatReaderFactory

- (id<MEFormatReader>)formatReaderWithByteSource:(MEByteSource *)primaryByteSource
                                         options:(MEFormatReaderInstantiationOptions *)options
                                           error:(NSError **)error {
    FMEAsset *asset = [[FMEAsset alloc] initWithByteSource:primaryByteSource error:error];
    return asset ? [[FMEFormatReader alloc] initWithAsset:asset] : nil;
}

@end


@implementation FMEFormatReader

- (instancetype)initWithAsset:(FMEAsset *)asset {
    if ((self = [super init])) _asset = asset;
    return self;
}

- (void)loadFileInfoWithCompletionHandler:(void (^)(MEFileInfo *, NSError *))completionHandler {
    MEFileInfo *info = [MEFileInfo new];
    info.duration = self.asset.duration;
    info.fragmentsStatus = MEFileInfoCouldNotContainFragments;
    completionHandler(info, nil);
}

- (void)loadMetadataWithCompletionHandler:(void (^)(NSArray<AVMetadataItem *> *, NSError *))completionHandler {
    completionHandler(@[], nil);
}

- (void)loadTrackReadersWithCompletionHandler:(void (^)(NSArray<id<METrackReader>> *, NSError *))completionHandler {
    NSMutableArray<id<METrackReader>> *readers = [NSMutableArray array];
    for (FMETrackReader *track in self.asset.tracks) {
        FMETrackReaderLease *lease = [FMETrackReaderLease new];
        lease.asset = self.asset;
        lease.track = track;
        [readers addObject:lease];
    }
    completionHandler(readers, nil);
}

@end
