//
//  TwilioVoicePushRegistry.h
//  TwilioVoiceReactNative
//
//  Copyright © 2022 Twilio, Inc. All rights reserved.
//

FOUNDATION_EXPORT NSString * const kTwilioVoicePushRegistryNotification;
FOUNDATION_EXPORT NSString * const kTwilioVoicePushRegistryEventType;
FOUNDATION_EXPORT NSString * const kTwilioVoicePushRegistryNotificationDeviceTokenUpdated;
FOUNDATION_EXPORT NSString * const kTwilioVoicePushRegistryNotificationDeviceTokenInvalidated;
FOUNDATION_EXPORT NSString * const kTwilioVoicePushRegistryNotificationDeviceToken;
FOUNDATION_EXPORT NSString * const kTwilioVoicePushRegistryNotificationIncomingPushReceived;
FOUNDATION_EXPORT NSString * const kTwilioVoicePushRegistryNotificationIncomingPushPayload;

// VoxNote diagnostic bridge. Events are persisted so PushKit/CallKit outcomes
// that occur during a cold start can be delivered after React Native is ready.
FOUNDATION_EXPORT NSString * const kVoxnoteTwilioCallDiagnosticPendingNotification;
FOUNDATION_EXPORT NSString * const kVoxnoteTwilioPendingCallDiagnosticsDefaultsKey;
FOUNDATION_EXPORT NSString * const kVoxnoteTwilioLastPushReceivedAtDefaultsKey;
FOUNDATION_EXPORT NSString * const kVoxnoteTwilioLastPushCompletionAtDefaultsKey;
FOUNDATION_EXPORT NSString * const kVoxnoteTwilioLastPushApplicationStateDefaultsKey;
FOUNDATION_EXPORT NSString * const kVoxnoteTwilioLastPushCallContextDefaultsKey;

FOUNDATION_EXPORT void VoxnotePersistTwilioCallDiagnosticEvent(NSDictionary<NSString *, id> *event);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *VoxnoteTwilioPushTimingMetadata(void);
FOUNDATION_EXPORT NSString *VoxnoteTwilioApplicationState(void);
FOUNDATION_EXPORT NSString *VoxnoteTwilioISO8601Timestamp(NSDate *date);

@interface TwilioVoicePushRegistry : NSObject

- (void)updatePushRegistry;

@end
