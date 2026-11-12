//
//  TwilioVoicePushRegistry.m
//  TwilioVoiceReactNative
//
//  Copyright © 2022 Twilio, Inc. All rights reserved.
//

@import PushKit;
@import Foundation;
@import TwilioVoice;
@import UIKit;

#import "TwilioVoicePushRegistry.h"
#import "TwilioVoiceReactNative.h"
#import "TwilioVoiceReactNativeConstants.h"

NSString * const kTwilioVoicePushRegistryNotification = @"TwilioVoicePushRegistryNotification";
NSString * const kTwilioVoicePushRegistryEventType = @"type";
NSString * const kTwilioVoicePushRegistryNotificationDeviceTokenUpdated = @"deviceTokenUpdated";
NSString * const kTwilioVoicePushRegistryNotificationDeviceTokenInvalidated = @"deviceTokenInvalidated";
NSString * const kTwilioVoicePushRegistryNotificationDeviceToken = @"deviceToken";
NSString * const kTwilioVoicePushRegistryNotificationIncomingPushReceived = @"incomingPushReceived";
NSString * const kTwilioVoicePushRegistryNotificationIncomingPushPayload = @"incomingPushPayload";
NSString * const kVoxnoteTwilioCallDiagnosticPendingNotification = @"VoxnoteTwilioCallDiagnosticPending";
NSString * const kVoxnoteTwilioPendingCallDiagnosticsDefaultsKey = @"voxnote_twilio_pending_call_diagnostics_v1";
NSString * const kVoxnoteTwilioLastPushReceivedAtDefaultsKey = @"voxnote_twilio_last_push_received_at_v1";
NSString * const kVoxnoteTwilioLastPushCompletionAtDefaultsKey = @"voxnote_twilio_last_push_completion_at_v1";
NSString * const kVoxnoteTwilioLastPushApplicationStateDefaultsKey = @"voxnote_twilio_last_push_application_state_v1";
NSString * const kVoxnoteTwilioLastPushCallContextDefaultsKey = @"voxnote_twilio_last_push_call_context_v1";

static const NSUInteger kVoxnoteTwilioMaximumPendingCallDiagnostics = 32;

NSString *VoxnoteTwilioISO8601Timestamp(NSDate *date) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    return [formatter stringFromDate:date ?: [NSDate date]];
}

NSString *VoxnoteTwilioApplicationState(void) {
    switch (UIApplication.sharedApplication.applicationState) {
        case UIApplicationStateActive:
            return @"active";
        case UIApplicationStateInactive:
            return @"inactive";
        case UIApplicationStateBackground:
            return @"background";
    }
    return @"unknown";
}

void VoxnotePersistTwilioCallDiagnosticEvent(NSDictionary<NSString *, id> *event) {
    if (event == nil) {
        return;
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    @synchronized (defaults) {
        NSArray *storedEvents = [defaults arrayForKey:kVoxnoteTwilioPendingCallDiagnosticsDefaultsKey] ?: @[];
        NSMutableArray *pendingEvents = [storedEvents mutableCopy];
        [pendingEvents addObject:event];
        if (pendingEvents.count > kVoxnoteTwilioMaximumPendingCallDiagnostics) {
            NSRange overflow = NSMakeRange(0, pendingEvents.count - kVoxnoteTwilioMaximumPendingCallDiagnostics);
            [pendingEvents removeObjectsInRange:overflow];
        }
        [defaults setObject:pendingEvents forKey:kVoxnoteTwilioPendingCallDiagnosticsDefaultsKey];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kVoxnoteTwilioCallDiagnosticPendingNotification
                                                            object:nil];
    });
}

NSDictionary<NSString *, id> *VoxnoteTwilioPushTimingMetadata(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDate *receivedAt = [defaults objectForKey:kVoxnoteTwilioLastPushReceivedAtDefaultsKey];
    NSDate *completionAt = [defaults objectForKey:kVoxnoteTwilioLastPushCompletionAtDefaultsKey];
    NSMutableDictionary<NSString *, id> *metadata = [NSMutableDictionary dictionary];

    if (receivedAt != nil) {
        metadata[@"pushReceivedAt"] = VoxnoteTwilioISO8601Timestamp(receivedAt);
        metadata[@"pushAgeMs"] = @([NSDate.date timeIntervalSinceDate:receivedAt] * 1000.0);
    }
    if (completionAt != nil && receivedAt != nil && [completionAt compare:receivedAt] != NSOrderedAscending) {
        metadata[@"pushCompletionAt"] = VoxnoteTwilioISO8601Timestamp(completionAt);
        metadata[@"pushProcessingDurationMs"] = @([completionAt timeIntervalSinceDate:receivedAt] * 1000.0);
    }

    NSString *applicationState = [defaults stringForKey:kVoxnoteTwilioLastPushApplicationStateDefaultsKey];
    if (applicationState != nil) {
        metadata[@"pushApplicationState"] = applicationState;
    }
    metadata[@"pushCompletionRecorded"] = @(completionAt != nil && receivedAt != nil && [completionAt compare:receivedAt] != NSOrderedAscending);
    return metadata;
}

@interface TwilioVoicePushRegistry () <PKPushRegistryDelegate>

@property (nonatomic, strong) PKPushRegistry *voipRegistry;
@property (nonatomic, copy) NSString *callInviteUuid;

@end

@implementation TwilioVoicePushRegistry

#pragma mark - TwilioVoicePushRegistry methods

- (void)updatePushRegistry {
    if (self.voipRegistry != nil) {
        return;
    }

    self.voipRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    self.voipRegistry.delegate = self;
    self.voipRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];

    NSDate *initializedAt = [NSDate date];
    VoxnotePersistTwilioCallDiagnosticEvent(@{
        @"eventName": @"pushkit_registry_initialized_native",
        @"phase": @"push",
        @"severity": @"info",
        @"occurredAt": VoxnoteTwilioISO8601Timestamp(initializedAt),
        @"metadata": @{
            @"nativeSource": @"twilio_voice_push_registry",
            @"applicationState": VoxnoteTwilioApplicationState(),
        },
    });
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry
didUpdatePushCredentials:(PKPushCredentials *)credentials
             forType:(NSString *)type {
    if ([type isEqualToString:PKPushTypeVoIP]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kTwilioVoicePushRegistryNotification
                                                            object:nil
                                                          userInfo:@{kTwilioVoicePushRegistryEventType: kTwilioVoicePushRegistryNotificationDeviceTokenUpdated,
                                                                     kTwilioVoicePushRegistryNotificationDeviceToken: credentials.token}];
    }
}

- (void)pushRegistry:(PKPushRegistry *)registry
didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
             forType:(PKPushType)type
withCompletionHandler:(void (^)(void))completion {
    if ([type isEqualToString:PKPushTypeVoIP]) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSDate *receivedAt = [NSDate date];
        NSDictionary<NSString *, id> *payloadDictionary = payload.dictionaryPayload ?: @{};
        [defaults setObject:receivedAt forKey:kVoxnoteTwilioLastPushReceivedAtDefaultsKey];
        [defaults removeObjectForKey:kVoxnoteTwilioLastPushCompletionAtDefaultsKey];
        [defaults removeObjectForKey:kVoxnoteTwilioLastPushCallContextDefaultsKey];
        [defaults setObject:VoxnoteTwilioApplicationState() forKey:kVoxnoteTwilioLastPushApplicationStateDefaultsKey];

        NSMutableDictionary<NSString *, id> *receiptMetadata = [@{
            @"nativeSource": @"twilio_voice_push_registry",
            @"applicationState": VoxnoteTwilioApplicationState(),
        } mutableCopy];
        NSString *pushCallSid = [payloadDictionary[@"twi_call_sid"] isKindOfClass:[NSString class]]
            ? payloadDictionary[@"twi_call_sid"]
            : nil;
        if (pushCallSid.length > 0) {
            receiptMetadata[@"twilioChildCallSid"] = pushCallSid;
        }
        NSDictionary<NSString *, id> *receiptEvent = @{
            @"eventName": @"pushkit_notification_received",
            @"phase": @"push",
            @"severity": @"info",
            @"occurredAt": VoxnoteTwilioISO8601Timestamp(receivedAt),
            @"metadata": receiptMetadata,
        };

        // Record the call-specific receipt before entering SDK code. The bounded
        // local buffer notifies JS asynchronously and never waits for an upload.
        VoxnotePersistTwilioCallDiagnosticEvent(receiptEvent);

        [[NSNotificationCenter defaultCenter] postNotificationName:kTwilioVoicePushRegistryNotification
                                                            object:nil
                                                          userInfo:@{kTwilioVoicePushRegistryEventType: kTwilioVoicePushRegistryNotificationIncomingPushReceived,
                                                                     kTwilioVoicePushRegistryNotificationIncomingPushPayload: payloadDictionary}];

        NSDate *completionAt = [NSDate date];
        completion();

        [defaults setObject:completionAt forKey:kVoxnoteTwilioLastPushCompletionAtDefaultsKey];
        NSMutableDictionary<NSString *, id> *metadata = [VoxnoteTwilioPushTimingMetadata() mutableCopy];
        metadata[@"nativeSource"] = @"twilio_voice_push_registry";
        metadata[@"applicationStateAtCompletion"] = VoxnoteTwilioApplicationState();
        NSDictionary *callContext = [defaults dictionaryForKey:kVoxnoteTwilioLastPushCallContextDefaultsKey];
        if (callContext != nil) {
            [metadata addEntriesFromDictionary:callContext];
        }
        NSDictionary<NSString *, id> *completionEvent = @{
            @"eventName": @"pushkit_completion_invoked",
            @"phase": @"push",
            @"severity": @"info",
            @"occurredAt": VoxnoteTwilioISO8601Timestamp(completionAt),
            @"metadata": metadata,
        };

        VoxnotePersistTwilioCallDiagnosticEvent(completionEvent);
        return;
    }

    completion();
}

- (void)pushRegistry:(PKPushRegistry *)registry
        didInvalidatePushTokenForType:(NSString *)type {
    if ([type isEqualToString:PKPushTypeVoIP]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kTwilioVoicePushRegistryNotification
                                                            object:nil
                                                          userInfo:@{kTwilioVoicePushRegistryEventType: kTwilioVoicePushRegistryNotificationDeviceTokenInvalidated}];
    }
}

@end
