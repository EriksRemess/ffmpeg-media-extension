#import "FMEAsset.h"

NSErrorDomain const FMEErrorDomain = @"lv.apps.ffmpeg-media-extension";

@interface FMEFormatReaderFactory : NSObject <MEFormatReaderExtension>
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
    completionHandler((NSArray<id<METrackReader>> *)self.asset.tracks, nil);
}

@end
