#import "FMETrackReader.h"

NS_ASSUME_NONNULL_BEGIN

@interface FMESampleCursor : NSObject <MESampleCursor>
- (instancetype)initWithTrack:(FMETrackReader *)track sample:(FMESample *)sample;
@end

NS_ASSUME_NONNULL_END

