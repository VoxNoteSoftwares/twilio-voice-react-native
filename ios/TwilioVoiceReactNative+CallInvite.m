//
//  TwilioVoiceReactNative+CallInvite.m
//  TwilioVoiceReactNative
//
//  Copyright © 2023 Twilio, Inc. All rights reserved.
//

@import TwilioVoice;

#import "TwilioVoiceReactNative.h"
#import "TwilioVoiceReactNativeConstants.h"

@interface TwilioVoiceReactNative (CallInvite) <TVONotificationDelegate>

@end

@implementation TwilioVoiceReactNative (CallInvite)

- (void)callInviteReceived:(TVOCallInvite *)callInvite {
    self.callInviteMap[callInvite.uuid.UUIDString] = callInvite;
    
    [self reportNewIncomingCall:callInvite];

    [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice
                       body:@{
                         kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventTypeValueIncomingCallInvite,
                         kTwilioVoiceReactNativeEventKeyCallInvite: [self callInviteInfo:callInvite]}];
}

- (void)cancelledCallInviteReceived:(TVOCancelledCallInvite *)cancelledCallInvite error:(NSError *)error {
    NSString *uuid;
    for (NSString *uuidKey in [self.callInviteMap allKeys]) {
        TVOCallInvite *callInvite = self.callInviteMap[uuidKey];
        if ([callInvite.callSid isEqualToString:cancelledCallInvite.callSid]) {
            uuid = uuidKey;
            break;
        }
    }
    if (uuid == nil) {
        // The invite may already have been removed after CallKit rejected the
        // incoming-call report. A later Twilio cancellation is then expected.
        NSLog(@"Ignoring cancellation for an invite that is no longer active: %@", cancelledCallInvite.callSid);
        [self voxnoteRefreshCallAudioOwnership];
        return;
    }
    self.cancelledCallInviteMap[uuid] = cancelledCallInvite;

    [self sendEventWithName:kTwilioVoiceReactNativeScopeCallInvite
                       body:@{
                         kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallInviteEventTypeValueCancelled,
                         kTwilioVoiceReactNativeCallInviteEventKeyCallSid: cancelledCallInvite.callSid,
                         kTwilioVoiceReactNativeEventKeyCancelledCallInvite: [self cancelledCallInviteInfo:cancelledCallInvite],
                         kTwilioVoiceReactNativeVoiceErrorKeyError: @{
                           kTwilioVoiceReactNativeVoiceErrorKeyCode: @(error.code),
                           kTwilioVoiceReactNativeVoiceErrorKeyMessage: [error localizedDescription]}}];
    
    [self.callInviteMap removeObjectForKey:uuid];
    [self voxnoteRefreshCallAudioOwnership];
    
    [self endCallWithUuid:[[NSUUID alloc] initWithUUIDString:uuid]];
}

@end
