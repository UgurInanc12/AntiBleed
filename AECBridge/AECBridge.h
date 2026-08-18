#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Swift-visible wrapper for AECProcessor (Phase 0 stub, Phase 4 real WebRTC).
@interface AECBridge : NSObject

- (BOOL)initializeWithSampleRate:(int)sampleRate;
- (BOOL)initializeWithSampleRate:(int)sampleRate
                captureChannels:(int)captureChannels
                 renderChannels:(int)renderChannels;

- (void)processRenderFrame:(const float *)render numSamples:(int)numSamples;
- (void)processCaptureFrame:(const float *)capture numSamples:(int)numSamples out:(float *)out;
- (NSDictionary<NSString *, id> *)getStats;
- (void)reset;
- (BOOL)isInitialized;

@end

NS_ASSUME_NONNULL_END
