#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>

// Run each case in a fresh process. This probe does not change caption preferences.
@interface CaptionObserver : NSObject <AVPlayerItemLegibleOutputPushDelegate>
@property(nonatomic) NSUInteger cueCount;
@end
@implementation CaptionObserver
- (void)legibleOutput:(AVPlayerItemLegibleOutput *)output
 didOutputAttributedStrings:(NSArray<NSAttributedString *> *)strings
 nativeSampleBuffers:(NSArray *)samples forItemTime:(CMTime)time {
    (void)output; (void)samples;
    for (NSAttributedString *text in strings) {
        if (text.length) {
            self.cueCount++;
            printf("CUE %.3f %s\n", CMTimeGetSeconds(time), text.string.UTF8String);
        }
    }
}
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc != 3) {
        fprintf(stderr, "usage: selection-player FILE auto|manual|forced|normal\n");
        return 64;
    }
    NSString *mode = @(argv[2]);
    if (![@[@"auto", @"manual", @"forced", @"normal"] containsObject:mode]) return 64;
    MTRegisterProfessionalVideoWorkflowFormatReaders();
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(argv[1])] options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    CaptionObserver *observer = [CaptionObserver new];
    AVPlayerItemLegibleOutput *output = [[AVPlayerItemLegibleOutput alloc] init];
    output.suppressesPlayerRendering = YES;
    [output setDelegate:observer queue:dispatch_get_main_queue()];
    [item addOutput:output];
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    player.appliesMediaSelectionCriteriaAutomatically = ![mode isEqualToString:@"manual"];
    if ([mode isEqualToString:@"forced"] || [mode isEqualToString:@"normal"]) {
        AVPlayerMediaSelectionCriteria *criteria = [[AVPlayerMediaSelectionCriteria alloc]
            initWithPreferredLanguages:@[@"en"]
            preferredMediaCharacteristics:[mode isEqualToString:@"forced"] ? @[AVMediaCharacteristicContainsOnlyForcedSubtitles] : @[]];
        [player setMediaSelectionCriteria:criteria forMediaCharacteristic:AVMediaCharacteristicLegible];
    }
    [player play];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while ([deadline timeIntervalSinceNow] > 0 && item.status != AVPlayerItemStatusFailed &&
           CMTimeGetSeconds(player.currentTime) < 3) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    [player pause];
    printf("MODE %s status=%ld time=%.3f cues=%lu error=%s\n", mode.UTF8String,
        (long)item.status, CMTimeGetSeconds(player.currentTime),
        (unsigned long)observer.cueCount, item.error.description.UTF8String ?: "none");
    for (AVPlayerItemTrack *track in item.tracks) {
        printf("TRACK %d type=%s enabled=%d\n", track.assetTrack.trackID,
            track.assetTrack.mediaType.UTF8String, track.enabled);
    }
    printf("SELECTION %s\n", item.currentMediaSelection.description.UTF8String);
    // Ready alone does not establish that playback advanced before the deadline.
    return item.status == AVPlayerItemStatusReadyToPlay &&
        CMTimeGetSeconds(player.currentTime) >= 3 ? 0 : 1;
} }
