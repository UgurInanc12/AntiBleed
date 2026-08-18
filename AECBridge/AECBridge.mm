#import "AECBridge.h"
#import "AECProcessor.hpp"

@interface AECBridge () {
    AECProcessor _processor;
}
@end

@implementation AECBridge

- (BOOL)initializeWithSampleRate:(int)sampleRate {
    return [self initializeWithSampleRate:sampleRate captureChannels:1 renderChannels:1];
}

- (BOOL)initializeWithSampleRate:(int)sampleRate
                captureChannels:(int)captureChannels
                 renderChannels:(int)renderChannels {
    AECConfig cfg;
    cfg.sampleRateHz = sampleRate;
    cfg.numCaptureChannels = captureChannels;
    cfg.numRenderChannels = renderChannels;
    return _processor.initialize(cfg) ? YES : NO;
}

- (void)processRenderFrame:(const float *)render numSamples:(int)numSamples {
    _processor.processRenderFrame(render, numSamples);
}

- (void)processCaptureFrame:(const float *)capture numSamples:(int)numSamples out:(float *)out {
    _processor.processCaptureFrame(capture, numSamples, out);
}

- (NSDictionary<NSString *, id> *)getStats {
    AECStats s = _processor.getStats();
    return @{
        @"delayMs": @(s.delayMs),
        @"delayMedianMs": @(s.delayMedianMs),
        @"delayStddevMs": @(s.delayStddevMs),
        @"echoReturnLoss": @(s.echoReturnLoss),
        @"echoReturnLossEnhancement": @(s.echoReturnLossEnhancement),
        @"divergentFilterFraction": @(s.divergentFilterFraction),
        @"residualEchoLikelihood": @(s.residualEchoLikelihood),
    };
}

- (void)reset {
    _processor.reset();
}

- (BOOL)isInitialized {
    return _processor.isInitialized() ? YES : NO;
}

@end
