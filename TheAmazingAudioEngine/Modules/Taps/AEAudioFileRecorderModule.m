//
//  AEAudioFileRecorderModule.m
//  TheAmazingAudioEngine
//
//  Created by Michael Tyson on 1/04/2016.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import "AEAudioFileRecorderModule.h"
#import "AEUtilities.h"
#import "AETypes.h"
#import "AEAudioBufferListUtilities.h"
#import "AEWeakRetainingProxy.h"
#import <AudioToolbox/AudioToolbox.h>

@interface AEAudioFileRecorderModule () {
    ExtAudioFileRef _audioFile;
    AEHostTicks    _startTime;
    AEHostTicks    _stopTime;
    BOOL           _complete;
    UInt32         _recordedFrames;
}
@property (nonatomic, readwrite) BOOL recording;
@property (nonatomic, copy) void (^completionBlock)();
@property (nonatomic, strong) NSTimer * pollTimer;
@end

@implementation AEAudioFileRecorderModule

- (instancetype)initWithRenderer:(AERenderer *)renderer URL:(NSURL *)url
                            type:(AEAudioFileType)type error:(NSError **)error {
    if ( !(self = [super initWithRenderer:renderer]) ) return nil;
    
    if ( !(_audioFile = AEExtAudioFileRefCreate(url, type, self.renderer.sampleRate, 2, error)) ) return nil;
    
    // Prime async recording
    ExtAudioFileWriteAsync(_audioFile, 0, NULL);
    
    self.processFunction = AEAudioFileRecorderModuleProcess;
    
    return self;
}

- (void)dealloc {
    if ( self.pollTimer ) {
        [self.pollTimer invalidate];
    }
    if ( _audioFile ) {
        [self finishWriting];
    }
}

- (void)beginRecordingAtTime:(AEHostTicks)time {
    self.recording = YES;
    _complete = NO;
    _recordedFrames = 0;
    _startTime = time ? time : AECurrentTimeInHostTicks();
}

- (void)stopRecordingAtTime:(AEHostTicks)time completionBlock:(AEAudioFileRecorderModuleCompletionBlock)block {
    self.completionBlock = block;
    _stopTime = time ? time : AECurrentTimeInHostTicks();
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:[AEWeakRetainingProxy proxyWithTarget:self]
                                                    selector:@selector(pollForCompletion) userInfo:nil repeats:YES];
}

static void AEAudioFileRecorderModuleProcess(__unsafe_unretained AEAudioFileRecorderModule * THIS,
                                        const AERenderContext * _Nonnull context) {
    
    if ( !THIS->_recording || THIS->_complete ) return;
    
    AEHostTicks startTime = THIS->_startTime;
    AEHostTicks stopTime = THIS->_stopTime;
    
    if ( stopTime && stopTime < context->timestamp->mHostTime ) {
        THIS->_complete = YES;
        return;
    }
    
    AEHostTicks hostTimeAtBufferEnd
        = context->timestamp->mHostTime + AEHostTicksFromSeconds((double)context->frames / context->sampleRate);
    if ( startTime && startTime > hostTimeAtBufferEnd ) {
        return;
    }
    
    THIS->_startTime = 0;
    
    const AudioBufferList * abl = AEBufferStackGet(context->stack, 0);
    if ( !abl ) return;
    
    // Prepare stereo buffer
    AEAudioBufferListCreateOnStack(stereoBuffer);
    for ( int i=0; i<stereoBuffer->mNumberBuffers; i++ ) {
        stereoBuffer->mBuffers[i] = abl->mBuffers[MIN(abl->mNumberBuffers-1, i)];
    }
    
    // Advance frames, if we have a start time mid-buffer
    UInt32 frames = context->frames;
    if ( startTime && startTime > context->timestamp->mHostTime ) {
        UInt32 advanceFrames = round(AESecondsFromHostTicks(startTime - context->timestamp->mHostTime) * context->sampleRate);
        for ( int i=0; i<stereoBuffer->mNumberBuffers; i++ ) {
            stereoBuffer->mBuffers[i].mData += AEAudioDescription.mBytesPerFrame * advanceFrames;
            stereoBuffer->mBuffers[i].mDataByteSize -= AEAudioDescription.mBytesPerFrame * advanceFrames;
        }
        frames -= advanceFrames;
    }
    
    // Truncate if we have a stop time mid-buffer
    if ( stopTime && stopTime < hostTimeAtBufferEnd ) {
        UInt32 truncateFrames = round(AESecondsFromHostTicks(hostTimeAtBufferEnd - stopTime) * context->sampleRate);
        for ( int i=0; i<stereoBuffer->mNumberBuffers; i++ ) {
            stereoBuffer->mBuffers[i].mDataByteSize -= AEAudioDescription.mBytesPerFrame * truncateFrames;
        }
        frames -= truncateFrames;
    }
    
    AECheckOSStatus(ExtAudioFileWriteAsync(THIS->_audioFile, frames, stereoBuffer), "ExtAudioFileWriteAsync");
    THIS->_recordedFrames += frames;
    
    if ( stopTime && stopTime < hostTimeAtBufferEnd ) {
        THIS->_complete = YES;
    }
}

- (void)pollForCompletion {
    if ( _complete ) {
        [self.pollTimer invalidate];
        self.pollTimer = nil;
        self.recording = NO;
        [self finishWriting];
        if ( self.completionBlock ) self.completionBlock();
        self.completionBlock = nil;
    }
}

- (void)finishWriting {
    AECheckOSStatus(ExtAudioFileDispose(_audioFile), "AudioFileClose");
    _audioFile = NULL;
}

@end
