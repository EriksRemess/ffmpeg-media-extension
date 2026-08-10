#import <Foundation/Foundation.h>
#import <MediaExtension/MediaExtension.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const FMEErrorDomain;

static inline NSError *FMEError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:FMEErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

static inline NSError *FMEMediaError(MEError code, NSString *message) {
    return [NSError errorWithDomain:MediaExtensionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static inline CMTime FMETime(int64_t value, int timescale) {
    return value == INT64_MIN ? kCMTimeInvalid : CMTimeMake(value, timescale > 0 ? timescale : 1000);
}

NS_ASSUME_NONNULL_END
