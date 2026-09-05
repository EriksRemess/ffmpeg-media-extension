// Standalone diagnostic: format creation/serialization success does not imply
// MediaExtension selection or playback support. Does not install a reader.
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
static void dump(NSString *label, CMFormatDescriptionRef format) {
    NSLog(@"%@ format=%@", label, format);
    if (!format) return;
    CMTextDisplayFlags flags = 0;
    OSStatus flagStatus = CMTextFormatDescriptionGetDisplayFlags(format, &flags);
    NSLog(@"display flags status=%d value=%u", (int)flagStatus, (unsigned)flags);
    CMBlockBufferRef serialized = NULL;
    OSStatus status = CMTextFormatDescriptionCopyAsBigEndianTextDescriptionBlockBuffer(NULL, format, NULL, &serialized);
    NSLog(@"serialize %d bytes=%zu", (int)status, serialized ? CMBlockBufferGetDataLength(serialized) : 0);
    if (serialized) CFRelease(serialized);
}
int main(void) { @autoreleasepool {
    static const uint8_t bytes[] = {0,0,0,31,'w','v','t','t',0,0,0,0,0,0,0,1,0,0,0,15,'v','t','t','C','W','E','B','V','T','T','\n'};
    CMFormatDescriptionRef format = NULL;
    OSStatus status = CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(NULL,bytes,sizeof(bytes),NULL,kCMMediaType_Subtitle,&format);
    NSLog(@"bridge create %d", (int)status); dump(@"bridge",format); if(format)CFRelease(format);
    NSDictionary *extensions = @{(__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: @{@"vttC": [@"WEBVTT\n" dataUsingEncoding:NSUTF8StringEncoding]}};
    format=NULL; status = CMFormatDescriptionCreate(NULL,kCMMediaType_Subtitle,kCMSubtitleFormatType_WebVTT,(__bridge CFDictionaryRef)extensions,&format);
    NSLog(@"generic create %d",(int)status); dump(@"generic",format); if(format)CFRelease(format);
    NSMutableDictionary *verbatim = [extensions mutableCopy];
    verbatim[(__bridge NSString *)kCMFormatDescriptionExtension_VerbatimSampleDescription] = [NSData dataWithBytes:bytes length:sizeof(bytes)];
    format=NULL; status = CMFormatDescriptionCreate(NULL,kCMMediaType_Subtitle,kCMSubtitleFormatType_WebVTT,(__bridge CFDictionaryRef)verbatim,&format);
    NSLog(@"verbatim create %d",(int)status); dump(@"verbatim",format); if(format)CFRelease(format);
} return 0; }
