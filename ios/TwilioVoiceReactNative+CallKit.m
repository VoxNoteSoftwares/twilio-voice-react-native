//
//  TwilioVoiceReactNative+CallKit.m
//  TwilioVoiceReactNative
//
//  Copyright © 2022 Twilio, Inc. All rights reserved.
//

@import CallKit;
@import TwilioVoice;
@import AVFoundation;

#import "TwilioVoiceReactNative.h"
#import "TwilioVoiceReactNativeConstants.h"
#import "TwilioVoicePushRegistry.h"
#import "VoxnoteCallDisplayName.h"

// Another call in progress (cellular or VoIP) turns a new incoming call into
// call waiting, which beeps instead of ringing.
static NSDictionary<NSString *, id> *VoxnoteOtherSystemCallsMetadata(NSUUID *incomingUuid) {
    NSInteger activeCount = 0;
    NSInteger onHoldCount = 0;
    for (CXCall *call in [[CXCallObserver alloc] init].calls) {
        if (call.hasEnded || [call.UUID isEqual:incomingUuid]) continue;
        activeCount += 1;
        if (call.isOnHold) onHoldCount += 1;
    }
    return @{
        @"otherActiveCallCount": @(activeCount),
        @"otherCallsOnHoldCount": @(onHoldCount),
    };
}

NSString * const kDefaultCallKitConfigurationName = @"Twilio Voice React Native";

static CXProvider *sVoxNoteDefaultCallingProvider;
static BOOL sVoxNoteDidPersistDefaultCallingProviderSelection = NO;
static NSUInteger sVoxNoteCallKitProviderGeneration = 0;
static NSString *sVoxNoteCallKitProviderSource = @"uninitialized";
// Pending diagnostic records are bounded; active calls copy their record into
// their existing timeline. Eviction means unknown, never another call's result.
static NSCache<NSString *, NSDictionary *> *VoxnotePendingConfigurationRefreshes(void) {
    static NSCache<NSString *, NSDictionary *> *records;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        records = [NSCache new];
        records.countLimit = 64;
    });
    return records;
}
static const int64_t kVoxnoteCallKitActivationDiagnosticDeadlineMs = 2000;

static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *VoxnoteCallKitTimelines(void) {
    static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, id> *> *timelines;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        timelines = [NSMutableDictionary dictionary];
    });
    return timelines;
}

static NSNumber *VoxnoteElapsedMilliseconds(NSDate *later, NSDate *earlier) {
    if (later == nil || earlier == nil) {
        return nil;
    }
    return @([later timeIntervalSinceDate:earlier] * 1000.0);
}

void VoxNoteRegisterDefaultCallingProvider(CXProvider *provider) {
    if (provider != nil && provider != sVoxNoteDefaultCallingProvider) {
        sVoxNoteCallKitProviderGeneration += 1;
        sVoxNoteCallKitProviderSource = @"bootstrap_registered";
    }
    sVoxNoteDefaultCallingProvider = provider;
}

CXProvider *VoxNoteDefaultCallingProvider(void) {
    return sVoxNoteDefaultCallingProvider;
}

static NSString *VoxnoteCallKitIncomingCallErrorReason(NSError *error) {
    if (![error.domain isEqualToString:CXErrorDomainIncomingCall]) {
        return @"other";
    }

    switch (error.code) {
        case 1:
            return @"unentitled";
        case 2:
            return @"call_uuid_already_exists";
        case 3:
            return @"filtered_by_do_not_disturb";
        case 4:
            return @"filtered_by_block_list";
        case 5:
            return @"filtered_during_restricted_sharing_mode";
        case 6:
            return @"call_is_protected";
        case 7:
            return @"filtered_by_sensitive_participants";
        default:
            return @"unknown";
    }
}

@interface TwilioVoiceReactNative (CallKit) <CXProviderDelegate, TVOCallDelegate, AVAudioPlayerDelegate>

// VoxNote patch: reconcile the call-safe AVAudioSession configuration and report
// route health. CallKit remains the sole owner of session activation and Twilio
// audio-device enablement.
- (void)voxnoteEnsureAudioReadyForActiveCall:(NSString *)reason callUuid:(NSString *)callUuid;
- (void)voxnoteRefreshCallKitConfigurationForUuid:(NSString *)callUuid reason:(NSString *)reason;
- (NSDictionary *)voxnoteConfigurationRefreshMetadataForUuid:(NSString *)callUuid;
- (BOOL)voxnoteRecoverCallKitProviderForTransactionError:(NSError *)error;
- (NSDictionary<NSString *, id> *)voxnoteCallDiagnosticMetadataForInvite:(TVOCallInvite *)callInvite;
- (NSDictionary<NSString *, id> *)voxnoteCallDiagnosticMetadataForUuid:(NSString *)callUuid;
- (NSDictionary<NSString *, id> *)voxnoteCallKitProviderMetadata:(CXProvider *)provider;
- (void)voxnoteRecordCallKitAction:(NSString *)actionType
                          callUuid:(NSString *)callUuid
                          provider:(CXProvider *)provider
                         startedAt:(NSDate *)startedAt;
- (void)voxnoteRecordCallObjectCreatedForUuid:(NSString *)callUuid;
- (void)voxnoteRecordCallKitActionCompletion:(NSString *)outcome callUuid:(NSString *)callUuid;
- (void)voxnoteScheduleActivationDeadlineForUuid:(NSString *)callUuid actionType:(NSString *)actionType;
- (void)voxnotePersistCallKitTeardownSummaryForCall:(TVOCall *)call;
- (void)voxnotePersistCallKitDiagnosticEvent:(NSString *)eventName
                                    severity:(NSString *)severity
                                    metadata:(NSDictionary<NSString *, id> *)metadata
                                  occurredAt:(NSDate *)occurredAt;

@end

@implementation TwilioVoiceReactNative (CallKit)

#pragma mark - CallKit helper methods

- (void)initializeCallKit {
    [self initializeCallKitWithConfiguration:nil];
}

- (void)initializeCallKitWithConfiguration:(NSDictionary *)configuration {
    CXProviderConfiguration *callKitConfiguration = [CXProviderConfiguration new];

    if (configuration[kTwilioVoiceReactNativeCallKitMaximumCallGroups]) {
        callKitConfiguration.maximumCallGroups = [configuration[kTwilioVoiceReactNativeCallKitMaximumCallGroups] intValue];
    } else {
        callKitConfiguration.maximumCallGroups = 1;
    }

    if (configuration[kTwilioVoiceReactNativeCallKitMaximumCallsPerCallGroup]) {
        callKitConfiguration.maximumCallsPerCallGroup = [configuration[kTwilioVoiceReactNativeCallKitMaximumCallsPerCallGroup] intValue];
    } else {
        callKitConfiguration.maximumCallsPerCallGroup = 1;
    }

    float version = [[UIDevice currentDevice].systemVersion floatValue];
    if (version > 11.0 && configuration[kTwilioVoiceReactNativeCallKitIncludesCallsInRecents]) {
        callKitConfiguration.includesCallsInRecents = [configuration[kTwilioVoiceReactNativeCallKitIncludesCallsInRecents] boolValue];
    }

    if (configuration[kTwilioVoiceReactNativeCallKitSupportedHandleTypes]) {
        NSSet *supportedHandleTypes = [NSSet setWithArray:configuration[kTwilioVoiceReactNativeCallKitSupportedHandleTypes]];
        callKitConfiguration.supportedHandleTypes = supportedHandleTypes;
    } else {
        callKitConfiguration.supportedHandleTypes = [NSSet setWithArray:@[@(CXHandleTypeGeneric), @(CXHandleTypePhoneNumber)]];
    }

    if (configuration[kTwilioVoiceReactNativeCallKitIconTemplateImageData] && [configuration[kTwilioVoiceReactNativeCallKitIconTemplateImageData] isKindOfClass:[NSString class]]) {
        UIImage *icon = [UIImage imageNamed:configuration[kTwilioVoiceReactNativeCallKitIconTemplateImageData]];
        callKitConfiguration.iconTemplateImageData = UIImagePNGRepresentation(icon);
    }

    if (configuration[kTwilioVoiceReactNativeCallKitRingtoneSound] && [configuration[kTwilioVoiceReactNativeCallKitRingtoneSound] isKindOfClass:[NSString class]]) {
        callKitConfiguration.ringtoneSound = configuration[kTwilioVoiceReactNativeCallKitRingtoneSound];
    }
    
    self.callKitConfiguration = callKitConfiguration;

    // Keep one provider for the lifetime of the native module. Replacing a
    // CXProvider can leave callservicesd pointing at a stale audio-session
    // association, which prevents didActivateAudioSession from being delivered.
    if (self.callKitProvider == nil) {
        CXProvider *bootstrapProvider = VoxNoteDefaultCallingProvider();
        if (bootstrapProvider != nil) {
            self.callKitProvider = bootstrapProvider;
            sVoxNoteCallKitProviderSource = @"bootstrap_adopted";
        } else {
            self.callKitProvider = [[CXProvider alloc] initWithConfiguration:callKitConfiguration];
            sVoxNoteCallKitProviderGeneration += 1;
            sVoxNoteCallKitProviderSource = @"module_fallback_created";
        }
        [self.callKitProvider setDelegate:self queue:nil];
    } else if (self.callKitProvider != VoxNoteDefaultCallingProvider()) {
        self.callKitProvider.configuration = callKitConfiguration;
    }

    if (self.callKitCallController == nil) {
        self.callKitCallController = [CXCallController new];
    }

    if (!sVoxNoteDidPersistDefaultCallingProviderSelection) {
        sVoxNoteDidPersistDefaultCallingProviderSelection = YES;
        BOOL adoptedBootstrapProvider = self.callKitProvider == VoxNoteDefaultCallingProvider();
        VoxnotePersistTwilioCallDiagnosticEvent(@{
            @"eventName": adoptedBootstrapProvider
                ? @"default_call_provider_adopted"
                : @"default_call_provider_fallback_created",
            @"phase": @"callkit",
            @"severity": adoptedBootstrapProvider ? @"info" : @"warning",
            @"occurredAt": VoxnoteTwilioISO8601Timestamp([NSDate date]),
            @"metadata": @{
                @"nativeSource": @"twilio_voice_react_native",
                @"bootstrapProviderAvailable": @(VoxNoteDefaultCallingProvider() != nil),
                @"adoptedBootstrapProvider": @(adoptedBootstrapProvider),
                @"bootstrapConfigurationPreserved": @(adoptedBootstrapProvider),
                @"providerGeneration": @(sVoxNoteCallKitProviderGeneration),
                @"providerSource": sVoxNoteCallKitProviderSource,
            },
        });
    }
}

- (void)voxnoteRefreshCallKitConfigurationForUuid:(NSString *)callUuid reason:(NSString *)reason {
    double startedUptime = NSProcessInfo.processInfo.systemUptime;
    CXProvider *provider = self.callKitProvider;
    CXProviderConfiguration *existingConfiguration = provider.configuration;
    NSString *outcome = @"skipped_missing_provider_or_configuration";
    if (provider != nil && existingConfiguration != nil) {
        // Experimental Apple DTS mitigation. Reassign this provider's OWN
        // configuration, including the bootstrap provider's ringtone/recents.
        // Never replace the provider, delegate, or activate AVAudioSession here.
        provider.configuration = existingConfiguration;
        outcome = @"refreshed_existing_provider";
    }
    NSDictionary *metadata = @{
        @"configurationRefreshOutcome": outcome,
        @"configurationRefreshReason": reason,
        @"configurationRefreshCallUuid": callUuid,
        @"configurationRefreshUptimeSeconds": @(startedUptime),
        @"configurationRefreshDurationMs": @((NSProcessInfo.processInfo.systemUptime - startedUptime) * 1000),
        @"configurationRefreshProviderGeneration": @(sVoxNoteCallKitProviderGeneration),
        @"configurationRefreshProviderSource": sVoxNoteCallKitProviderSource ?: @"unknown",
        @"configurationRefreshMatchesBootstrap": @(provider != nil && provider == VoxNoteDefaultCallingProvider()),
    };
    [VoxnotePendingConfigurationRefreshes() setObject:metadata forKey:callUuid];
}

- (NSDictionary *)voxnoteConfigurationRefreshMetadataForUuid:(NSString *)callUuid {
    if (callUuid.length == 0) return @{@"configurationRefreshOutcome": @"not_observed_for_call"};
    return VoxnoteCallKitTimelines()[callUuid][@"configurationRefresh"]
        ?: [VoxnotePendingConfigurationRefreshes() objectForKey:callUuid]
        ?: @{@"configurationRefreshOutcome": @"not_observed_for_call"};
}

- (BOOL)voxnoteRecoverCallKitProviderForTransactionError:(NSError *)error {
    BOOL isUnknownProviderError =
        [error.domain isEqualToString:@"com.apple.CallKit.error.requesttransaction"] &&
        error.code == 2;
    if (!isUnknownProviderError) {
        return NO;
    }

    if (self.callKitProvider == nil && VoxNoteDefaultCallingProvider() != nil) {
        self.callKitProvider = VoxNoteDefaultCallingProvider();
        sVoxNoteCallKitProviderSource = @"app_delegate_bootstrap_recovered";
    }

    CXProvider *provider = self.callKitProvider;
    if (provider == nil) {
        [self voxnotePersistCallKitDiagnosticEvent:@"callkit_provider_recovery_failed"
                                         severity:@"error"
                                         metadata:@{
                                             @"errorDomain": error.domain ?: @"unknown",
                                             @"errorCode": @(error.code),
                                             @"reason": @"provider_unavailable",
                                         }
                                       occurredAt:[NSDate date]];
        return NO;
    }

    // Experimental recovery: reassert the existing provider configuration and
    // recreate only the controller. This attempts to repair stale CallKit state;
    // only a later successful transaction can confirm recovery.
    CXProviderConfiguration *existingConfiguration = provider.configuration;
    [provider setDelegate:self queue:nil];
    if (existingConfiguration != nil) {
        provider.configuration = existingConfiguration;
    }
    self.callKitCallController = [CXCallController new];

    NSMutableDictionary<NSString *, id> *metadata =
        [[self voxnoteCallKitProviderMetadata:provider] mutableCopy];
    metadata[@"errorDomain"] = error.domain ?: @"unknown";
    metadata[@"errorCode"] = @(error.code);
    metadata[@"configurationRefreshOutcome"] = existingConfiguration != nil ? @"reasserted_after_unknown_provider" : @"skipped_missing_configuration";
    metadata[@"providerReused"] = @YES;
    metadata[@"callControllerRecreated"] = @YES;
    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_provider_recovery_attempted"
                                     severity:@"warning"
                                     metadata:metadata
                                   occurredAt:[NSDate date]];
    return YES;
}

- (NSString *)getDisplayName:(NSString *)template
            customParameters:(NSDictionary<NSString *, NSString *> *)customParameters {
    NSString *processedTemplate = template;
    for (NSString *paramKey in customParameters) {
        NSString *paramValue = customParameters[paramKey];
        NSString *wrappedParamKey = [NSString stringWithFormat:@"${%@}", paramKey];
        processedTemplate = [processedTemplate stringByReplacingOccurrencesOfString:wrappedParamKey withString:paramValue];
    }
    return processedTemplate;
}

- (BOOL)isPhoneNumber:(NSString *)string {
    if (string == nil || [string length] < 3) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"+0123456789"];
    return [[string stringByTrimmingCharactersInSet:allowed] length] == 0;
}

- (NSDictionary<NSString *, id> *)voxnoteCallDiagnosticMetadataForInvite:(TVOCallInvite *)callInvite {
    NSDictionary<NSString *, NSString *> *parameters = callInvite.customParameters ?: @{};
    NSString *(^firstParameter)(NSArray<NSString *> *) = ^NSString *(NSArray<NSString *> *keys) {
        for (NSString *key in keys) {
            NSString *value = parameters[key];
            if ([value isKindOfClass:[NSString class]] && value.length > 0) {
                return value;
            }
        }
        return nil;
    };

    NSString *childCallSid = firstParameter(@[@"ChildCallSid", @"childCallSid"]) ?: callInvite.callSid;
    NSString *parentCallSid = firstParameter(@[@"ParentCallSid", @"parentCallSid", @"CallSid", @"callSid"]);
    NSString *callCorrelationId = firstParameter(@[@"callCorrelationId", @"CallCorrelationId", @"CallSid", @"callSid"])
        ?: parentCallSid
        ?: childCallSid
        ?: callInvite.uuid.UUIDString;

    NSMutableDictionary<NSString *, id> *metadata = [@{
        @"nativeSource": @"twilio_voice_react_native",
        @"nativeCallUuid": callInvite.uuid.UUIDString ?: @"unknown",
        @"applicationState": VoxnoteTwilioApplicationState(),
        @"callKitProviderAvailable": @(self.callKitProvider != nil),
        @"callKitConfigurationAvailable": @(self.callKitConfiguration != nil),
        @"processUptimeSeconds": @(NSProcessInfo.processInfo.systemUptime),
    } mutableCopy];
    if (callCorrelationId != nil) metadata[@"callCorrelationId"] = callCorrelationId;
    if (parentCallSid != nil) metadata[@"twilioParentCallSid"] = parentCallSid;
    if (childCallSid != nil) metadata[@"twilioChildCallSid"] = childCallSid;
    [metadata addEntriesFromDictionary:[self voxnoteConfigurationRefreshMetadataForUuid:callInvite.uuid.UUIDString]];
    [metadata addEntriesFromDictionary:VoxnoteTwilioPushTimingMetadata()];
    return metadata;
}

- (NSDictionary<NSString *, id> *)voxnoteCallKitProviderMetadata:(CXProvider *)provider {
    return @{
        @"providerGeneration": @(sVoxNoteCallKitProviderGeneration),
        @"providerSource": sVoxNoteCallKitProviderSource ?: @"unknown",
        @"providerMatchesModule": @(provider != nil && provider == self.callKitProvider),
        @"providerMatchesBootstrap": @(provider != nil && provider == VoxNoteDefaultCallingProvider()),
        @"bootstrapProviderAvailable": @(VoxNoteDefaultCallingProvider() != nil),
    };
}

- (NSDictionary<NSString *, id> *)voxnoteCallDiagnosticMetadataForUuid:(NSString *)callUuid {
    TVOCallInvite *callInvite = callUuid != nil ? self.callInviteMap[callUuid] : nil;
    if (callInvite != nil) {
        NSMutableDictionary<NSString *, id> *metadata = [[self voxnoteCallDiagnosticMetadataForInvite:callInvite] mutableCopy];
        [metadata addEntriesFromDictionary:[self voxnoteCallKitProviderMetadata:self.callKitProvider]];
        metadata[@"activationCallbackObserved"] = @(VoxnoteCallKitTimelines()[callUuid][@"activationCallbackAt"] != nil);
        return metadata;
    }

    TVOCall *call = callUuid != nil ? self.callMap[callUuid] : nil;
    NSDictionary<NSString *, NSString *> *parameters = self.twimlParams ?: @{};
    NSString *callCorrelationId = parameters[@"callCorrelationId"];
    NSMutableDictionary<NSString *, id> *metadata = [@{
        @"nativeSource": @"twilio_voice_react_native",
        @"nativeCallUuid": callUuid ?: @"unknown",
        @"applicationState": VoxnoteTwilioApplicationState(),
        @"callKitProviderAvailable": @(self.callKitProvider != nil),
        @"callKitConfigurationAvailable": @(self.callKitConfiguration != nil),
        @"processUptimeSeconds": @(NSProcessInfo.processInfo.systemUptime),
    } mutableCopy];
    if ([callCorrelationId isKindOfClass:[NSString class]] && callCorrelationId.length > 0) {
        metadata[@"callCorrelationId"] = callCorrelationId;
    }
    if (call.sid.length > 0) {
        metadata[@"twilioChildCallSid"] = call.sid;
    }
    // The invite is removed after answer. Retain its correlation instead of
    // attributing an inbound callback to the last outbound twimlParams.
    [metadata addEntriesFromDictionary:VoxnoteCallKitTimelines()[callUuid][@"callCorrelationContext"] ?: @{}];
    [metadata addEntriesFromDictionary:[self voxnoteCallKitProviderMetadata:self.callKitProvider]];
    [metadata addEntriesFromDictionary:[self voxnoteConfigurationRefreshMetadataForUuid:callUuid]];
    metadata[@"activationCallbackObserved"] = @(VoxnoteCallKitTimelines()[callUuid][@"activationCallbackAt"] != nil);
    return metadata;
}

- (void)voxnoteRecordCallKitAction:(NSString *)actionType
                          callUuid:(NSString *)callUuid
                          provider:(CXProvider *)provider
                         startedAt:(NSDate *)startedAt {
    if (callUuid.length == 0) {
        return;
    }
    NSMutableDictionary<NSString *, id> *timeline = [@{
        @"actionType": actionType ?: @"unknown",
        @"actionStartedAt": startedAt ?: [NSDate date],
        @"providerGeneration": @(sVoxNoteCallKitProviderGeneration),
        @"providerSource": sVoxNoteCallKitProviderSource ?: @"unknown",
    } mutableCopy];
    NSDictionary *callMetadata = [self voxnoteCallDiagnosticMetadataForUuid:callUuid];
    NSMutableDictionary *callContext = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"callCorrelationId", @"twilioParentCallSid", @"twilioChildCallSid"]) {
        if (callMetadata[key] != nil) callContext[key] = callMetadata[key];
    }
    timeline[@"callCorrelationContext"] = callContext;
    timeline[@"configurationRefresh"] = [self voxnoteConfigurationRefreshMetadataForUuid:callUuid];
    VoxnoteCallKitTimelines()[callUuid] = timeline;
    [VoxnotePendingConfigurationRefreshes() removeObjectForKey:callUuid];

    NSMutableDictionary<NSString *, id> *metadata = [[self voxnoteCallDiagnosticMetadataForUuid:callUuid] mutableCopy];
    [metadata addEntriesFromDictionary:[self voxnoteCallKitProviderMetadata:provider]];
    metadata[@"actionType"] = actionType ?: @"unknown";
    metadata[@"audioDeviceEnabledAtAction"] = @([TwilioVoiceReactNative twilioAudioDevice].enabled);
    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_action_started"
                                     severity:@"info"
                                     metadata:metadata
                                   occurredAt:startedAt];
}

- (void)voxnoteRecordCallObjectCreatedForUuid:(NSString *)callUuid {
    NSMutableDictionary<NSString *, id> *timeline = VoxnoteCallKitTimelines()[callUuid];
    if (timeline != nil) {
        timeline[@"callObjectCreatedAt"] = [NSDate date];
    }
}

- (void)voxnoteRecordCallKitActionCompletion:(NSString *)outcome callUuid:(NSString *)callUuid {
    NSDate *completedAt = [NSDate date];
    NSMutableDictionary<NSString *, id> *timeline = VoxnoteCallKitTimelines()[callUuid];
    if (timeline != nil) {
        timeline[@"actionCompletedAt"] = completedAt;
        timeline[@"actionOutcome"] = outcome ?: @"unknown";
    }
    NSMutableDictionary<NSString *, id> *metadata = [[self voxnoteCallDiagnosticMetadataForUuid:callUuid] mutableCopy];
    metadata[@"actionType"] = timeline[@"actionType"] ?: @"unknown";
    metadata[@"actionOutcome"] = outcome ?: @"unknown";
    NSNumber *actionDurationMs = VoxnoteElapsedMilliseconds(completedAt, timeline[@"actionStartedAt"]);
    if (actionDurationMs != nil) metadata[@"actionDurationMs"] = actionDurationMs;
    NSNumber *callCreationDurationMs = VoxnoteElapsedMilliseconds(timeline[@"callObjectCreatedAt"], timeline[@"actionStartedAt"]);
    if (callCreationDurationMs != nil) metadata[@"callObjectCreationDurationMs"] = callCreationDurationMs;
    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_action_completed"
                                     severity:[outcome isEqualToString:@"fulfilled"] ? @"info" : @"error"
                                     metadata:metadata
                                   occurredAt:completedAt];
}

- (void)voxnoteScheduleActivationDeadlineForUuid:(NSString *)callUuid actionType:(NSString *)actionType {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kVoxnoteCallKitActivationDiagnosticDeadlineMs * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        NSMutableDictionary<NSString *, id> *timeline = VoxnoteCallKitTimelines()[callUuid];
        if (self.callMap[callUuid] == nil || timeline[@"audioActivatedAt"] != nil) {
            return;
        }
        NSDate *recordedAt = [NSDate date];
        timeline[@"activationMissingRecordedAt"] = recordedAt;
        NSMutableDictionary<NSString *, id> *metadata = [[self voxnoteCallDiagnosticMetadataForUuid:callUuid] mutableCopy];
        metadata[@"actionType"] = actionType ?: @"unknown";
        metadata[@"deadlineMs"] = @(kVoxnoteCallKitActivationDiagnosticDeadlineMs);
        metadata[@"actionOutcome"] = timeline[@"actionOutcome"] ?: @"pending";
        metadata[@"audioDeviceEnabled"] = @([TwilioVoiceReactNative twilioAudioDevice].enabled);
        NSNumber *elapsedMs = VoxnoteElapsedMilliseconds(recordedAt, timeline[@"actionStartedAt"]);
        if (elapsedMs != nil) metadata[@"elapsedSinceActionMs"] = elapsedMs;
        [self voxnotePersistCallKitDiagnosticEvent:@"callkit_activation_missing"
                                         severity:@"error"
                                         metadata:metadata
                                       occurredAt:recordedAt];
    });
}

- (void)voxnotePersistCallKitTeardownSummaryForCall:(TVOCall *)call {
    NSString *callUuid = call.uuid.UUIDString;
    NSMutableDictionary<NSString *, id> *timeline = VoxnoteCallKitTimelines()[callUuid];
    if (timeline == nil || timeline[@"activationMissingRecordedAt"] == nil) {
        return;
    }

    NSDate *teardownAt = [NSDate date];
    NSMutableDictionary<NSString *, id> *metadata = [[self voxnoteCallDiagnosticMetadataForUuid:callUuid] mutableCopy];
    metadata[@"actionType"] = timeline[@"actionType"] ?: @"unknown";
    metadata[@"actionOutcome"] = timeline[@"actionOutcome"] ?: @"unknown";
    metadata[@"activationObservedBeforeTeardown"] = @(timeline[@"audioActivatedAt"] != nil);
    metadata[@"audioDeviceEnabledAtTeardown"] = @([TwilioVoiceReactNative twilioAudioDevice].enabled);
    NSNumber *connectedDurationMs = VoxnoteElapsedMilliseconds(teardownAt, timeline[@"callConnectedAt"]);
    if (connectedDurationMs != nil) metadata[@"connectedDurationMs"] = connectedDurationMs;

    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_activation_teardown_summary"
                                     severity:@"warning"
                                     metadata:metadata
                                   occurredAt:teardownAt];
}

- (void)voxnotePersistCallKitDiagnosticEvent:(NSString *)eventName
                                    severity:(NSString *)severity
                                    metadata:(NSDictionary<NSString *, id> *)metadata
                                  occurredAt:(NSDate *)occurredAt {
    VoxnotePersistTwilioCallDiagnosticEvent(@{
        @"eventName": eventName,
        @"phase": @"callkit",
        @"severity": severity,
        @"occurredAt": VoxnoteTwilioISO8601Timestamp(occurredAt),
        @"metadata": metadata ?: @{},
    });
}

- (void)reportNewIncomingCall:(TVOCallInvite *)callInvite {
    // Claim audio before CallKit can surface an answer action or JavaScript runs.
    [self voxnoteSetCallAudioOwned:YES];
    NSString *handleName = callInvite.from;
    if (handleName == nil) {
        handleName = @"Unknown Caller";
    }

    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *preferenceKey = @"incomingCallContactHandleTemplate";
    if ([preferences objectForKey:preferenceKey] != nil) {
        const NSString *preferenceVal = [preferences stringForKey:preferenceKey];
        if ([preferenceVal length] > 0) {
            handleName = [self getDisplayName:preferenceVal customParameters:[callInvite customParameters]];
        }
    }

    // Use CXHandleTypePhoneNumber when the caller is a phone number
    // so iOS can automatically resolve contact names from the address book
    NSString *rawFrom = callInvite.from;
    CXHandleType handleType = CXHandleTypeGeneric;
    NSString *handleValue = handleName;
    if (rawFrom != nil && [self isPhoneNumber:rawFrom]) {
        handleType = CXHandleTypePhoneNumber;
        handleValue = rawFrom;
    }

    CXHandle *callHandle = [[CXHandle alloc] initWithType:handleType value:handleValue];

    CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
    callUpdate.remoteHandle = callHandle;
    // Preserve custom caller names and the raw remoteHandle used by Recents.
    callUpdate.localizedCallerName = [handleName isEqualToString:rawFrom]
        ? VoxnoteCallDisplayName(handleName) : handleName;
    callUpdate.supportsDTMF = YES;
    callUpdate.supportsHolding = YES;
    callUpdate.supportsGrouping = NO;
    callUpdate.supportsUngrouping = NO;
    callUpdate.hasVideo = NO;

    [self voxnoteRefreshCallKitConfigurationForUuid:callInvite.uuid.UUIDString reason:@"before_incoming_report"];
    NSDate *reportStartedAt = [NSDate date];
    NSMutableDictionary<NSString *, id> *inviteMetadata = [[self voxnoteCallDiagnosticMetadataForInvite:callInvite] mutableCopy];
    [inviteMetadata addEntriesFromDictionary:VoxnoteOtherSystemCallsMetadata(callInvite.uuid)];
    NSDictionary<NSString *, id> *baseDiagnosticMetadata = [inviteMetadata copy];
    [self.callKitProvider reportNewIncomingCallWithUUID:callInvite.uuid update:callUpdate completion:^(NSError *error) {
        NSDate *reportCompletedAt = [NSDate date];
        NSNumber *reportDurationMs = @([reportCompletedAt timeIntervalSinceDate:reportStartedAt] * 1000.0);
        NSDictionary<NSString *, id> *pushTimingMetadata = VoxnoteTwilioPushTimingMetadata();
        if (!error) {
            NSLog(@"Incoming call successfully reported.");
        } else {
            NSLog(@"Failed to report incoming call: %@.", error);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary<NSString *, id> *completionMetadata = [baseDiagnosticMetadata mutableCopy];
            completionMetadata[@"reportDurationMs"] = reportDurationMs;
            completionMetadata[@"applicationStateAtCompletion"] = VoxnoteTwilioApplicationState();
            [completionMetadata addEntriesFromDictionary:pushTimingMetadata];
            if (!error) {
                [self voxnotePersistCallKitDiagnosticEvent:@"callkit_report_succeeded"
                                                 severity:@"info"
                                                 metadata:completionMetadata
                                               occurredAt:reportCompletedAt];
            } else {
                completionMetadata[@"errorDomain"] = error.domain ?: @"unknown";
                completionMetadata[@"errorCode"] = @(error.code);
                completionMetadata[@"errorDescription"] = error.localizedDescription ?: @"unknown";
                completionMetadata[@"errorReason"] = VoxnoteCallKitIncomingCallErrorReason(error);
                [self voxnotePersistCallKitDiagnosticEvent:@"callkit_report_failed"
                                                 severity:@"error"
                                                 metadata:completionMetadata
                                               occurredAt:reportCompletedAt];

                BOOL duplicateCall = [error.domain isEqualToString:CXErrorDomainIncomingCall] && error.code == 2;
                if (!duplicateCall && self.callInviteMap[callInvite.uuid.UUIDString] == callInvite) {
                    [self.callInviteMap removeObjectForKey:callInvite.uuid.UUIDString];
                    [self sendEventWithName:kTwilioVoiceReactNativeScopeCallInvite
                                       body:@{
                                         kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallInviteEventTypeValueRejected,
                                         kTwilioVoiceReactNativeCallInviteEventKeyCallSid: callInvite.callSid,
                                         kTwilioVoiceReactNativeEventKeyCallInvite: [self callInviteInfo:callInvite]}];
                    @try {
                        [callInvite reject];
                    } @catch (NSException *exception) {
                        NSLog(@"Failed to reject an unreported call invite: %@", exception);
                    }
                }
                [self voxnoteRefreshCallAudioOwnership];
            }
        });
    }];

    // Keep persistence and diagnostics bridge work off the deadline-sensitive
    // path before CallKit is notified about the incoming VoIP call.
    [[NSUserDefaults standardUserDefaults] setObject:@{
        @"callCorrelationId": baseDiagnosticMetadata[@"callCorrelationId"] ?: @"",
        @"twilioParentCallSid": baseDiagnosticMetadata[@"twilioParentCallSid"] ?: @"",
        @"twilioChildCallSid": baseDiagnosticMetadata[@"twilioChildCallSid"] ?: @"",
        @"nativeCallUuid": baseDiagnosticMetadata[@"nativeCallUuid"] ?: @"",
    } forKey:kVoxnoteTwilioLastPushCallContextDefaultsKey];
    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_report_started"
                                     severity:@"info"
                                     metadata:baseDiagnosticMetadata
                                   occurredAt:reportStartedAt];
}

- (void)answerCallInvite:(NSUUID *)uuid
              completion:(void(^)(BOOL success, NSError *error))completionHandler {
    if (self.callKitCompletionCallback != nil) {
        NSError *error = [NSError errorWithDomain:@"TwilioVoiceReactNative"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Another CallKit operation is already pending"}];
        completionHandler(NO, error);
        return;
    }

    self.callKitCompletionCallback = completionHandler;
    CXAnswerCallAction *answerCallAction = [[CXAnswerCallAction alloc] initWithCallUUID:uuid];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:answerCallAction];

    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            // NOTE: this failure path never invokes `self.callKitCompletionCallback`,
            // which has two consequences:
            //
            //   1. The completion block in `callInvite_accept` never runs, so the
            //      promise returned by `CallInvite.accept()` never settles.
            //   2. That same block is what removes this call's entries from
            //      `iceServersMap` and `iceTransportPolicyMap`, so those entries
            //      leak for the lifetime of the app session.
            //
            // Invoking the callback with a failure here would address both. Left
            // as-is to keep this change scoped; (1) predates the ICE options work.
            //
            // See VBLOCKS-7039
            NSLog(@"Failed to submit answer-call transaction request: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self voxnoteCompleteCallKitOperation:NO error:error];
                [self voxnoteRefreshCallAudioOwnership];
            });
        } else {
            NSLog(@"Answer-call transaction successfully done");
        }
    }];
}

- (void)voxnoteCompleteCallKitOperation:(BOOL)success error:(NSError * _Nullable)error {
    void (^completionHandler)(BOOL, NSError *) = self.callKitCompletionCallback;
    self.callKitCompletionCallback = nil;
    if (completionHandler != nil) {
        completionHandler(success, error);
    }
}

- (void)endCallWithUuid:(NSUUID *)uuid {
    CXEndCallAction *endCallAction = [[CXEndCallAction alloc] initWithCallUUID:uuid];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:endCallAction];

    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            NSLog(@"Failed to submit end-call transaction request: %@", error);
        } else {
            NSLog(@"End-call transaction successfully done");
        }
    }];
}

- (void)makeCallWithAccessToken:(NSString *)accessToken
                         params:(NSDictionary *)params
                  contactHandle:(NSString *)contactHandle
                     iceServers:(NSArray<NSDictionary *> * _Nullable)iceServers
             iceTransportPolicy:(NSString * _Nullable)iceTransportPolicy
                       resolver:(RCTPromiseResolveBlock)resolver {
    self.accessToken = accessToken;
    self.twimlParams = params;

    NSString *handle = @"Default Contact";
    if ([contactHandle length] > 0) {
        handle = contactHandle;
    }

    CXHandleType handleType = [self isPhoneNumber:handle] ? CXHandleTypePhoneNumber : CXHandleTypeGeneric;
    CXHandle *callHandle = [[CXHandle alloc] initWithType:handleType value:handle];
    NSUUID *uuid = [NSUUID UUID];

    if (iceServers) {
        self.iceServersMap[uuid.UUIDString] = iceServers;
    }
    if (iceTransportPolicy) {
        self.iceTransportPolicyMap[uuid.UUIDString] = iceTransportPolicy;
    }

    // Stored before the transaction starts. The completion block below can run
    // on any queue and is the settle path when the transaction fails, so it has
    // to be able to find the resolver as soon as it runs.
    [self storeCallPromiseResolver:resolver forUuid:uuid.UUIDString];

    CXStartCallAction *startCallAction = [[CXStartCallAction alloc] initWithCallUUID:uuid handle:callHandle];
    CXTransaction *transaction = [[CXTransaction alloc] initWithAction:startCallAction];
    [self voxnoteRefreshCallKitConfigurationForUuid:uuid.UUIDString reason:@"before_outgoing_transaction"];
    NSDictionary *refreshMetadata = [self voxnoteConfigurationRefreshMetadataForUuid:uuid.UUIDString];

    [self.callKitCallController requestTransaction:transaction completion:^(NSError *error) {
        if (error) {
            NSLog(@"StartCallAction transaction request failed: %@", [error localizedDescription]);

            // The entries stored above are otherwise only removed in
            // `performVoiceCallWithUUID`, which never runs when the transaction
            // fails, so clear them here.
            //
            // NOTE: `iceServersMap` and `iceTransportPolicyMap` are
            // unsynchronized `NSMutableDictionary`s accessed from more than one
            // queue -- written from the React Native bridge queue (here, and in
            // `callInvite_accept`), read and removed on the main queue (the
            // `perform*` methods, where read-then-remove is also not atomic),
            // and removed here on whichever queue CallKit invokes this block on.
            // Concurrent mutation of an `NSMutableDictionary` is unsafe.
            //
            // In practice this is hard to hit: it needs a failed start-call
            // transaction to overlap with another call being placed or accepted.
            // Guarding every access behind a single lock -- ideally by funneling
            // the map access through store/take/clear helpers -- would resolve
            // it, along with the pre-existing bridge/main race that this block
            // is not the cause of.
            //
            // See VBLOCKS-7040
            [self.iceServersMap removeObjectForKey:uuid.UUIDString];
            [self.iceTransportPolicyMap removeObjectForKey:uuid.UUIDString];

            // Settle the promise `voice_connect_ios` handed over (upstream). Taken rather
            // than read, so `performVoiceCallWithUUID` cannot settle it too.
            RCTPromiseResolveBlock resolver = [self takeCallPromiseResolverForUuid:uuid.UUIDString];
            dispatch_async(dispatch_get_main_queue(), ^{
                [VoxnotePendingConfigurationRefreshes() removeObjectForKey:uuid.UUIDString];
                [self voxnoteRecoverCallKitProviderForTransactionError:error];
                NSString *message = [NSString stringWithFormat:
                                     @"CallKit rejected the start-call transaction: %@",
                                     error.localizedDescription ?: @"unknown error"];
                if ([error.domain isEqualToString:@"com.apple.CallKit.error.requesttransaction"] && error.code == 2) {
                    // The SDK preserves the message but drops NSError domain/code.
                    // Keep a stable discriminator alongside the localized description.
                    message = [@"[VOXNOTE_CALLKIT_UNKNOWN_PROVIDER] " stringByAppendingString:message];
                }
                if (resolver) {
                    [self rejectPromiseWithName:resolver
                                           name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                                        message:message];
                }
                [self voxnoteRefreshCallAudioOwnership];
            });
        } else {
            NSLog(@"StartCallAction transaction request successful");

            CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];

            callUpdate.remoteHandle = callHandle;
            callUpdate.localizedCallerName = VoxnoteCallDisplayName(handle);
            callUpdate.supportsDTMF = YES;
            callUpdate.supportsHolding = YES;
            callUpdate.supportsGrouping = NO;
            callUpdate.supportsUngrouping = NO;
            callUpdate.hasVideo = NO;

            [self.callKitProvider reportCallWithUUID:uuid updated:callUpdate];
        }
    }];
    // Persist after submitting the transaction; the captured record is immutable
    // and cannot inherit a previous incoming call's refresh outcome.
    NSMutableDictionary *metadata = [[self voxnoteCallDiagnosticMetadataForUuid:uuid.UUIDString] mutableCopy];
    [metadata addEntriesFromDictionary:refreshMetadata];
    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_configuration_refresh"
                                     severity:@"info" metadata:metadata occurredAt:[NSDate date]];
}

- (BOOL)performVoiceCallWithUUID:(NSUUID *)uuid
                          client:(NSString *)client
                      completion:(void(^)(BOOL success, NSError *error))completionHandler {

    NSString *uuidString = uuid.UUIDString;
    BOOL usedCachedIceConfiguration = NO;
    TVOIceOptions *iceOptions = [self voxnoteIceOptionsForUuid:uuidString
                                     usedCachedConfiguration:&usedCachedIceConfiguration];

    TVOConnectOptions *connectOptions =
    [TVOConnectOptions optionsWithAccessToken:self.accessToken
                                        block:^(TVOConnectOptionsBuilder *builder) {
        builder.params = self.twimlParams;
        builder.uuid = uuid;
        builder.callMessageDelegate = self;

        if (iceOptions) {
            builder.iceOptions = iceOptions;
        }
    }];

    TVOCall *call = [TwilioVoiceSDK connectWithOptions:connectOptions delegate:self];

    // Taken rather than read, so the transaction's completion block cannot
    // settle this promise as well. A nil `call` used to fall through without
    // settling it at all, which left `Voice.connect()` pending for the lifetime
    // of the application.
    RCTPromiseResolveBlock resolver = [self takeCallPromiseResolverForUuid:uuidString];
    if (call) {
        self.callMap[call.uuid.UUIDString] = call;
        if (usedCachedIceConfiguration && self.iceGenerationId != nil) {
            self.callIceGenerationMap[call.uuid.UUIDString] = self.iceGenerationId;
        }
        if (resolver) {
            [self resolvePromise:resolver value:[self callInfo:call]];
        }
        self.callKitCompletionCallback = completionHandler;
        return YES;
    }

    NSError *error = [NSError errorWithDomain:@"TwilioVoiceReactNative"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Twilio could not create the outbound call"}];
    if (resolver) {
        [self rejectPromiseWithName:resolver
                               name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                            message:error.localizedDescription];
    }
    [self voxnoteRefreshCallAudioOwnership];
    completionHandler(NO, error);
    return NO;
}

- (BOOL)performAnswerVoiceCallWithUUID:(NSUUID *)uuid
                            completion:(void(^)(BOOL success))completionHandler {
    TVOCallInvite *callInvite = self.callInviteMap[uuid.UUIDString];
    if (!callInvite) {
        NSLog(@"Cannot answer an invite that is no longer active: %@", uuid.UUIDString);
        NSError *error = [NSError errorWithDomain:@"TwilioVoiceReactNative"
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"The call invite is no longer active"}];
        [self voxnoteCompleteCallKitOperation:NO error:error];
        [self voxnoteRefreshCallAudioOwnership];
        completionHandler(NO);
        return NO;
    }

    BOOL usedCachedIceConfiguration = NO;
    TVOIceOptions *iceOptions = [self voxnoteIceOptionsForUuid:uuid.UUIDString
                                     usedCachedConfiguration:&usedCachedIceConfiguration];

    TVOAcceptOptions *acceptOptions = [TVOAcceptOptions optionsWithCallInvite:callInvite block:^(TVOAcceptOptionsBuilder *builder) {
        builder.uuid = uuid;
        builder.callMessageDelegate = self;
        if (iceOptions != nil) {
            builder.iceOptions = iceOptions;
        }
    }];

    TVOCall *call = [callInvite acceptWithOptions:acceptOptions delegate:self];

    if (!call) {
		[self.callInviteMap removeObjectForKey:uuid.UUIDString];
		NSError *error = [NSError errorWithDomain:@"TwilioVoiceReactNative"
		                                     code:-1
		                                 userInfo:@{NSLocalizedDescriptionKey: @"Twilio could not accept the call invite"}];
		[self voxnoteCompleteCallKitOperation:NO error:error];
		[self voxnoteRefreshCallAudioOwnership];
        completionHandler(NO);
		return NO;
    }

    self.callMap[call.uuid.UUIDString] = call;
    if (usedCachedIceConfiguration && self.iceGenerationId != nil) {
        self.callIceGenerationMap[call.uuid.UUIDString] = self.iceGenerationId;
    }

    [self sendEventWithName:kTwilioVoiceReactNativeScopeCallInvite
                       body:@{
                         kTwilioVoiceReactNativeCallInviteEventKeyType: kTwilioVoiceReactNativeCallInviteEventTypeValueAccepted,
                         kTwilioVoiceReactNativeCallInviteEventKeyCallSid: callInvite.callSid,
                         kTwilioVoiceReactNativeEventKeyCallInvite: [self callInviteInfo:callInvite]}];
	return YES;
}

- (void)updateCall:(NSString *)uuid callerHandle:(NSString *)handle {
    CXHandleType handleType = [self isPhoneNumber:handle] ? CXHandleTypePhoneNumber : CXHandleTypeGeneric;
    CXHandle *callHandle = [[CXHandle alloc] initWithType:handleType value:handle];
    CXCallUpdate *callUpdate = [[CXCallUpdate alloc] init];
    callUpdate.remoteHandle = callHandle;
    callUpdate.localizedCallerName = VoxnoteCallDisplayName(handle);
    callUpdate.supportsDTMF = YES;
    callUpdate.supportsHolding = YES;
    callUpdate.supportsGrouping = NO;
    callUpdate.supportsUngrouping = NO;
    callUpdate.hasVideo = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.callKitProvider reportCallWithUUID:[[NSUUID alloc] initWithUUIDString:uuid] updated:callUpdate];
    });
}

#pragma mark - VoxNote audio recovery

// Reconcile call-safe category/mode and record route health when a call is active.
// CallKit owns session activation. Twilio's audio device is enabled only from
// didActivateAudioSession, as required by the Twilio CallKit integration contract.
- (void)voxnoteEnsureAudioReadyForActiveCall:(NSString *)reason callUuid:(NSString *)callUuid {
    if (self.callMap.count == 0) {
        NSLog(@"[VoxNote][audio] ensure(%@): no active call, skipping", reason);
        return;
    }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    TVODefaultAudioDevice *device = [TwilioVoiceReactNative twilioAudioDevice];

    AVAudioSessionCategory categoryBefore = session.category;
    AVAudioSessionMode modeBefore = session.mode;
    NSArray *inputPortTypesBefore = [session.currentRoute.inputs valueForKeyPath:@"portType"];
    NSArray *outputPortTypesBefore = [session.currentRoute.outputs valueForKeyPath:@"portType"];
    NSUInteger inputCountBefore = session.currentRoute.inputs.count;
    NSUInteger outputCountBefore = session.currentRoute.outputs.count;
    BOOL enabledBefore = device.enabled;
    NSArray *activeCallUuids = self.callMap.allKeys;
    NSString *activeCallUuid = callUuid;
    NSString *attributionStatus = @"matched_native_uuid";
    if (activeCallUuid == nil && activeCallUuids.count == 1) {
        activeCallUuid = activeCallUuids[0];
        attributionStatus = @"single_active_call";
    } else if (activeCallUuid == nil) {
        attributionStatus = @"ambiguous";
    } else if (self.callMap[activeCallUuid] == nil) {
        attributionStatus = @"unmatched_native_uuid";
    }
    TVOCall *activeCall = activeCallUuid != nil ? self.callMap[activeCallUuid] : nil;
    NSString *activeCallSid = activeCall != nil ? activeCall.sid : nil;
    NSError *categoryError = nil;
    BOOL setCategoryAttempted = NO;

    // 1. Ensure the session can capture the microphone. expo-video / expo-audio can
    //    leave it as .playback / .moviePlayback, which has no input path, so even an
    //    enabled audio unit would produce no outbound RTP. Match the option set the
    //    Twilio audio device uses for two-way VoIP routing (HFP + A2DP). Note: a
    //    selected speaker route (overrideOutputAudioPort) is not re-applied here, so
    //    a call recovered on this path may fall back to the default route.
    BOOL categoryAllowsInput = [categoryBefore isEqualToString:AVAudioSessionCategoryPlayAndRecord];
    BOOL modeIsVoice = [modeBefore isEqualToString:AVAudioSessionModeVoiceChat];
    if (!categoryAllowsInput || !modeIsVoice) {
        setCategoryAttempted = YES;
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                        mode:AVAudioSessionModeVoiceChat
                     options:AVAudioSessionCategoryOptionAllowBluetooth | AVAudioSessionCategoryOptionAllowBluetoothA2DP
                       error:&categoryError];
        if (categoryError) {
            NSLog(@"[VoxNote][audio] ensure(%@): setCategory failed: %@", reason, categoryError);
        }
    }

    NSLog(@"[VoxNote][audio] ensure(%@): enabled %d->%d category %@->%@ mode %@->%@ otherAudio=%d",
          reason, enabledBefore, device.enabled,
          categoryBefore, session.category, modeBefore, session.mode,
          session.isOtherAudioPlaying);

    NSArray *inputPortTypesAfter = [session.currentRoute.inputs valueForKeyPath:@"portType"];
    NSArray *outputPortTypesAfter = [session.currentRoute.outputs valueForKeyPath:@"portType"];
    BOOL finalHealthy = device.enabled
        && [session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]
        && [session.mode isEqualToString:AVAudioSessionModeVoiceChat]
        && session.currentRoute.inputs.count > 0
        && session.currentRoute.outputs.count > 0;
    BOOL changedState = enabledBefore != device.enabled
        || ![categoryBefore isEqualToString:session.category]
        || ![modeBefore isEqualToString:session.mode]
        || inputCountBefore != session.currentRoute.inputs.count
        || outputCountBefore != session.currentRoute.outputs.count;
    NSString *severity = finalHealthy ? (changedState ? @"warning" : @"debug") : @"error";

    NSMutableDictionary *metadata = [@{
        @"reason": reason ?: @"unknown",
        @"severity": severity,
        @"nativeCallUuid": activeCallUuid ?: [NSNull null],
        @"attributionStatus": attributionStatus,
        @"callSid": activeCallSid ?: [NSNull null],
        @"categoryBefore": categoryBefore ?: @"unknown",
        @"categoryAfter": session.category ?: @"unknown",
        @"modeBefore": modeBefore ?: @"unknown",
        @"modeAfter": session.mode ?: @"unknown",
        @"audioDeviceEnabledBefore": @(enabledBefore),
        @"audioDeviceEnabledAfter": @(device.enabled),
        @"inputCountBefore": @(inputCountBefore),
        @"inputCountAfter": @(session.currentRoute.inputs.count),
        @"outputCountBefore": @(outputCountBefore),
        @"outputCountAfter": @(session.currentRoute.outputs.count),
        @"inputPortTypesBefore": inputPortTypesBefore ?: @[],
        @"inputPortTypesAfter": inputPortTypesAfter ?: @[],
        @"outputPortTypesBefore": outputPortTypesBefore ?: @[],
        @"outputPortTypesAfter": outputPortTypesAfter ?: @[],
        @"setCategoryAttempted": @(setCategoryAttempted),
        @"finalHealthy": @(finalHealthy)
    } mutableCopy];
    if (categoryError) {
        metadata[@"setCategoryErrorDomain"] = categoryError.domain ?: @"unknown";
        metadata[@"setCategoryErrorCode"] = @(categoryError.code);
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"VoxnoteTwilioAudioRecoveryAttempt"
                                                        object:self
                                                      userInfo:metadata];
}

#pragma mark - CXProviderDelegate

- (void)providerDidReset:(CXProvider *)provider {
    [TwilioVoiceReactNative twilioAudioDevice].enabled = NO;
    [VoxnoteCallKitTimelines() removeAllObjects];
    [VoxnotePendingConfigurationRefreshes() removeAllObjects];
    NSLog(@"[VoxNote][audio] providerDidReset -> enabled=NO");
}

- (void)providerDidBegin:(CXProvider *)provider {

}

- (void)provider:(CXProvider *)provider didActivateAudioSession:(AVAudioSession *)audioSession {
    NSDate *callbackAt = [NSDate date];
    NSArray<NSString *> *callUuids = self.callMap.allKeys;
    // Record the real delegate entry even with no tracked call, before SDK
    // enablement. This separates callback delivery from later audio handling.
    NSMutableDictionary *callbackMetadata = [[self voxnoteCallKitProviderMetadata:provider] mutableCopy];
    callbackMetadata[@"nativeSource"] = @"twilio_voice_react_native";
    callbackMetadata[@"applicationState"] = VoxnoteTwilioApplicationState();
    callbackMetadata[@"processUptimeSeconds"] = @(NSProcessInfo.processInfo.systemUptime);
    callbackMetadata[@"activeCallCount"] = @(callUuids.count);
    callbackMetadata[@"pendingInviteCount"] = @(self.callInviteMap.count);
    callbackMetadata[@"audioDeviceEnabled"] = @([TwilioVoiceReactNative twilioAudioDevice].enabled);
    for (NSString *callUuid in callUuids) {
        if (VoxnoteCallKitTimelines()[callUuid] == nil) VoxnoteCallKitTimelines()[callUuid] = [NSMutableDictionary dictionary];
        VoxnoteCallKitTimelines()[callUuid][@"activationCallbackAt"] = callbackAt;
    }
    if (callUuids.count == 1) [callbackMetadata addEntriesFromDictionary:[self voxnoteCallDiagnosticMetadataForUuid:callUuids.firstObject]];
    [callbackMetadata addEntriesFromDictionary:[self voxnoteCallKitProviderMetadata:provider]];
    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_activation_callback_received"
                                     severity:@"info" metadata:callbackMetadata occurredAt:callbackAt];
    NSDate *activatedAt = [NSDate date];
    for (NSString *callUuid in self.callMap.allKeys) {
        NSMutableDictionary<NSString *, id> *timeline = VoxnoteCallKitTimelines()[callUuid];
        if (timeline == nil) {
            timeline = [NSMutableDictionary dictionary];
            VoxnoteCallKitTimelines()[callUuid] = timeline;
        }
        timeline[@"audioActivatedAt"] = activatedAt;

        NSMutableDictionary<NSString *, id> *metadata = [[self voxnoteCallDiagnosticMetadataForUuid:callUuid] mutableCopy];
        [metadata addEntriesFromDictionary:[self voxnoteCallKitProviderMetadata:provider]];
        metadata[@"actionType"] = timeline[@"actionType"] ?: @"unknown";
        NSNumber *activationLatencyMs = VoxnoteElapsedMilliseconds(activatedAt, timeline[@"actionStartedAt"]);
        if (activationLatencyMs != nil) metadata[@"activationLatencyMs"] = activationLatencyMs;
        metadata[@"categoryAtActivation"] = audioSession.category ?: @"unknown";
        metadata[@"modeAtActivation"] = audioSession.mode ?: @"unknown";
        metadata[@"inputCountAtActivation"] = @(audioSession.currentRoute.inputs.count);
        metadata[@"outputCountAtActivation"] = @(audioSession.currentRoute.outputs.count);
        [self voxnotePersistCallKitDiagnosticEvent:@"callkit_activation_timeline"
                                         severity:@"info"
                                         metadata:metadata
                                       occurredAt:activatedAt];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"VoxnoteTwilioCallKitAudioSessionActivated"
                                                        object:self
                                                      userInfo:nil];
    [TwilioVoiceReactNative twilioAudioDevice].enabled = YES;
    NSLog(@"[VoxNote][audio] didActivateAudioSession -> enabled=YES (category=%@ mode=%@ otherAudio=%d)",
          audioSession.category, audioSession.mode, audioSession.isOtherAudioPlaying);
    [self voxnoteEnsureAudioReadyForActiveCall:@"didActivateAudioSession" callUuid:nil];
}

- (void)provider:(CXProvider *)provider didDeactivateAudioSession:(AVAudioSession *)audioSession {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"VoxnoteTwilioCallKitAudioSessionDeactivated"
                                                        object:self
                                                      userInfo:nil];
    [TwilioVoiceReactNative twilioAudioDevice].enabled = NO;
    NSLog(@"[VoxNote][audio] didDeactivateAudioSession -> enabled=NO");
}

- (void)provider:(CXProvider *)provider performEndCallAction:(CXEndCallAction *)action {
    // A local end while the invite still rings (lock button, decline, or the
    // system) explains calls that showed briefly and stopped. Record it before
    // the invite leaves the map and loses its correlation.
    NSString *endedUuid = action.callUUID.UUIDString;
    NSMutableDictionary<NSString *, id> *endMetadata = [[self voxnoteCallDiagnosticMetadataForUuid:endedUuid] mutableCopy];
    endMetadata[@"endTarget"] = self.callMap[endedUuid] ? @"call" : (self.callInviteMap[endedUuid] ? @"invite" : @"unknown");
    [self voxnotePersistCallKitDiagnosticEvent:@"callkit_end_action_received"
                                     severity:@"info"
                                     metadata:endMetadata
                                   occurredAt:[NSDate date]];
    if (self.callMap[action.callUUID.UUIDString]) {
        TVOCall *call = self.callMap[action.callUUID.UUIDString];
        [call disconnect];
    } else if (self.callInviteMap[action.callUUID.UUIDString]) {
        TVOCallInvite *callInvite = self.callInviteMap[action.callUUID.UUIDString];
        // Remove from map first to prevent double-processing from cancelledCallInviteReceived:
        [self.callInviteMap removeObjectForKey:action.callUUID.UUIDString];
		[self voxnoteRefreshCallAudioOwnership];
        // The native TVOCallInvite may already be invalidated if the caller cancelled,
        // which causes reject to throw NSInvalidArgumentException.
        @try {
            [callInvite reject];
        } @catch (NSException *exception) {
            NSLog(@"[TwilioVoiceReactNative] Failed to reject call invite (likely already cancelled): %@", exception);
        }
        [self sendEventWithName:kTwilioVoiceReactNativeScopeCallInvite
                           body:@{
                             kTwilioVoiceReactNativeCallInviteEventKeyType: kTwilioVoiceReactNativeCallInviteEventTypeValueRejected,
                             kTwilioVoiceReactNativeCallInviteEventKeyCallSid: callInvite.callSid,
                             kTwilioVoiceReactNativeEventKeyCallInvite: [self callInviteInfo:callInvite]}];
    }

    [action fulfill];
}

- (void)provider:(CXProvider *)provider performStartCallAction:(CXStartCallAction *)action {
    NSDate *actionStartedAt = [NSDate date];
    NSString *startedUuid = action.callUUID.UUIDString;
    [self voxnoteRecordCallKitAction:@"start" callUuid:startedUuid provider:provider startedAt:actionStartedAt];
    [self voxnoteSetCallAudioOwned:YES];
    [TwilioVoiceReactNative twilioAudioDevice].enabled = NO;
    [TwilioVoiceReactNative twilioAudioDevice].block();

    [self.callKitProvider reportOutgoingCallWithUUID:action.callUUID startedConnectingAtDate:[NSDate date]];

    __weak typeof(self) weakSelf = self;
    BOOL callCreated = [self performVoiceCallWithUUID:action.callUUID client:nil completion:^(BOOL success, NSError *error) {
        __strong typeof(self) strongSelf = weakSelf;
        if (success) {
            NSLog(@"performVoiceCallWithUUID successful");
            [strongSelf.callKitProvider reportOutgoingCallWithUUID:action.callUUID connectedAtDate:[NSDate date]];
        } else {
            NSLog(@"performVoiceCallWithUUID failed");
        }
    }];
    if (callCreated) {
        [self voxnoteRecordCallObjectCreatedForUuid:startedUuid];
    }
    
    // Observe route health shortly after CallKit processes the action. This may
    // repair category/mode, but deliberately leaves activation to CallKit.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.callMap[startedUuid]) {
            [self voxnoteEnsureAudioReadyForActiveCall:@"performStartCallAction+400ms" callUuid:startedUuid];
        }
    });

    if (callCreated) {
        [self voxnoteRecordCallKitActionCompletion:@"fulfilled" callUuid:startedUuid];
        [self voxnoteScheduleActivationDeadlineForUuid:startedUuid actionType:@"start"];
        [action fulfill];
    } else {
        [self voxnoteRecordCallKitActionCompletion:@"failed" callUuid:startedUuid];
        [VoxnoteCallKitTimelines() removeObjectForKey:startedUuid];
        [action fail];
    }
}

- (void)provider:(CXProvider *)provider performAnswerCallAction:(CXAnswerCallAction *)action {
    NSDate *actionStartedAt = [NSDate date];
    NSString *answeredUuid = action.callUUID.UUIDString;
    [self voxnoteRecordCallKitAction:@"answer" callUuid:answeredUuid provider:provider startedAt:actionStartedAt];
    [TwilioVoiceReactNative twilioAudioDevice].enabled = NO;
    [TwilioVoiceReactNative twilioAudioDevice].block();
    
    BOOL callCreated = [self performAnswerVoiceCallWithUUID:action.callUUID completion:^(BOOL success) {
        if (success) {
            NSLog(@"performAnswerVoiceCallWithUUID successful");
        } else {
            NSLog(@"performAnswerVoiceCallWithUUID failed");
        }
    }];
    if (callCreated) {
        [self voxnoteRecordCallObjectCreatedForUuid:answeredUuid];
    }
        
    // Observe route health shortly after answering. If didActivateAudioSession
    // has not fired, diagnostics will report the disabled device and empty route;
    // this check does not race CallKit by activating the session itself.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.callMap[answeredUuid]) {
            [self voxnoteEnsureAudioReadyForActiveCall:@"performAnswerCallAction+400ms" callUuid:answeredUuid];
        }
    });

    if (callCreated) {
        [self voxnoteRecordCallKitActionCompletion:@"fulfilled" callUuid:answeredUuid];
        [self voxnoteScheduleActivationDeadlineForUuid:answeredUuid actionType:@"answer"];
        [action fulfill];
    } else {
        [self voxnoteRecordCallKitActionCompletion:@"failed" callUuid:answeredUuid];
        [VoxnoteCallKitTimelines() removeObjectForKey:answeredUuid];
        [action fail];
    }
}

- (void)provider:(CXProvider *)provider performSetHeldCallAction:(CXSetHeldCallAction *)action {
    if (self.callMap[action.callUUID.UUIDString]) {
        TVOCall *call = self.callMap[action.callUUID.UUIDString];
        [call setOnHold:action.isOnHold];
        [action fulfill];
    } else {
        [action fail];
    }
}

- (void)provider:(CXProvider *)provider performSetMutedCallAction:(CXSetMutedCallAction *)action {
    if (self.callMap[action.callUUID.UUIDString]) {
        TVOCall *call = self.callMap[action.callUUID.UUIDString];
        [call setMuted:action.isMuted];
        [action fulfill];
    } else {
        [action fail];
    }
}

- (void)provider:(CXProvider *)provider performPlayDTMFCallAction:(CXPlayDTMFCallAction *)action {
    if (self.callMap[action.callUUID.UUIDString]) {
        TVOCall *call = self.callMap[action.callUUID.UUIDString];
        [call sendDigits:action.digits];
        [action fulfill];
    } else {
        [action fail];
    }
}

#pragma mark - TVOCallDelegate

- (void)callDidStartRinging:(TVOCall *)call {
    [self playRingback];

    [self sendEventWithName:kTwilioVoiceReactNativeScopeCall
                       body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventRinging,
                              kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call]}];
}

- (void)callDidConnect:(TVOCall *)call {
    NSDate *connectedAt = [NSDate date];
    self.callConnectMap[call.uuid.UUIDString] = [self getSimplifiedISO8601FormattedTimestamp:connectedAt];

    [self stopRingback];

    // By connect time the CallKit callback should have enabled the audio device.
    // Reconcile category/mode and emit native route-health diagnostics.
    [self voxnoteEnsureAudioReadyForActiveCall:@"callDidConnect" callUuid:call.uuid.UUIDString];

    NSMutableDictionary<NSString *, id> *timeline = VoxnoteCallKitTimelines()[call.uuid.UUIDString];
    if (timeline == nil) {
        timeline = [NSMutableDictionary dictionary];
        VoxnoteCallKitTimelines()[call.uuid.UUIDString] = timeline;
    }
    timeline[@"callConnectedAt"] = connectedAt;
    NSMutableDictionary<NSString *, id> *timelineMetadata = [[self voxnoteCallDiagnosticMetadataForUuid:call.uuid.UUIDString] mutableCopy];
    timelineMetadata[@"actionType"] = timeline[@"actionType"] ?: @"unknown";
    timelineMetadata[@"actionOutcome"] = timeline[@"actionOutcome"] ?: @"unknown";
    timelineMetadata[@"activationObservedBeforeConnect"] = @(timeline[@"audioActivatedAt"] != nil);
    timelineMetadata[@"audioDeviceEnabledAtConnect"] = @([TwilioVoiceReactNative twilioAudioDevice].enabled);
    NSNumber *actionToConnectMs = VoxnoteElapsedMilliseconds(connectedAt, timeline[@"actionStartedAt"]);
    if (actionToConnectMs != nil) timelineMetadata[@"actionToConnectMs"] = actionToConnectMs;
    NSNumber *callObjectToConnectMs = VoxnoteElapsedMilliseconds(connectedAt, timeline[@"callObjectCreatedAt"]);
    if (callObjectToConnectMs != nil) timelineMetadata[@"callObjectToConnectMs"] = callObjectToConnectMs;
    NSNumber *actionToActivationMs = VoxnoteElapsedMilliseconds(timeline[@"audioActivatedAt"], timeline[@"actionStartedAt"]);
    if (actionToActivationMs != nil) timelineMetadata[@"actionToActivationMs"] = actionToActivationMs;
    [self voxnotePersistCallKitDiagnosticEvent:@"native_call_connection_timeline"
                                     severity:timeline[@"audioActivatedAt"] != nil ? @"info" : @"warning"
                                     metadata:timelineMetadata
                                   occurredAt:connectedAt];

    [self sendEventWithName:kTwilioVoiceReactNativeScopeCall
                       body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventConnected,
                              kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call]}];

    [self voxnoteCompleteCallKitOperation:YES error:nil];
}

- (void)call:(TVOCall *)call didDisconnectWithError:(NSError *)error {
    NSDictionary *messageBody = [NSDictionary dictionary];
    if (error) {
        messageBody = @{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventDisconnected,
                        kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call],
                        kTwilioVoiceReactNativeVoiceErrorKeyError: @{kTwilioVoiceReactNativeVoiceErrorKeyCode: @(error.code),
                                                                     kTwilioVoiceReactNativeVoiceErrorKeyMessage: [error localizedDescription]}};
    } else {
        messageBody = @{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventDisconnected,
                        kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call]};
    }

    [self sendEventWithName:kTwilioVoiceReactNativeScopeCall body:messageBody];

    if (!self.userInitiatedDisconnect) {
        CXCallEndedReason reason = CXCallEndedReasonRemoteEnded;
        if (error) {
            reason = CXCallEndedReasonFailed;
        }

        [self.callKitProvider reportCallWithUUID:call.uuid endedAtDate:[NSDate date] reason:reason];
    }

    [self callDisconnected:call];
}

- (void)call:(TVOCall *)call didFailToConnectWithError:(NSError *)error {
    [self sendEventWithName:kTwilioVoiceReactNativeScopeCall
                       body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventConnectFailure,
                              kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call],
                              kTwilioVoiceReactNativeVoiceErrorKeyError: @{kTwilioVoiceReactNativeVoiceErrorKeyCode: @(error.code),
                                                                           kTwilioVoiceReactNativeVoiceErrorKeyMessage: [error localizedDescription]}}];

    [self voxnoteCompleteCallKitOperation:NO error:error];
    [self.callKitProvider reportCallWithUUID:call.uuid endedAtDate:[NSDate date] reason:CXCallEndedReasonFailed];

    [self callDisconnected:call];
}

- (void)callDisconnected:(TVOCall *)call {
    [self voxnotePersistCallKitTeardownSummaryForCall:call];
    for (NSString *uuidKey in [self.callMap allKeys]) {
        TVOCall *activeCall = self.callMap[uuidKey];
        if (activeCall == call) {
            [self.callMap removeObjectForKey:uuidKey];
            [self.callConnectMap removeObjectForKey:call.uuid.UUIDString];
            [self.callIceGenerationMap removeObjectForKey:call.uuid.UUIDString];
            [VoxnoteCallKitTimelines() removeObjectForKey:call.uuid.UUIDString];
            break;
        }
    }

    // Remove the corresponding call invite only when the incoming call is finished.
    [self.callInviteMap removeObjectForKey:call.uuid.UUIDString];
    [self voxnoteRefreshCallAudioOwnership];
    
    [self stopRingback];
    self.userInitiatedDisconnect = NO;
}

- (void)call:(TVOCall *)call isReconnectingWithError:(NSError *)error {
    [self sendEventWithName:kTwilioVoiceReactNativeScopeCall
                       body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventReconnecting,
                              kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call],
                              kTwilioVoiceReactNativeVoiceErrorKeyError: @{kTwilioVoiceReactNativeVoiceErrorKeyCode: @(error.code),
                                                                           kTwilioVoiceReactNativeVoiceErrorKeyMessage: [error localizedDescription]}}];
}

- (void)callDidReconnect:(TVOCall *)call {
    [self sendEventWithName:kTwilioVoiceReactNativeScopeCall
                       body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventReconnected,
                              kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call]}];
}

- (void)call:(TVOCall *)call
didReceiveQualityWarnings:(NSSet<NSNumber *> *)currentWarnings
previousWarnings:(NSSet<NSNumber *> *)previousWarnings {
    NSMutableArray<NSString *> *currentWarningEvents = [NSMutableArray array];
    for (NSNumber *warning in currentWarnings) {
        NSString *event = [self warningNameWithNumber:warning];
        [currentWarningEvents addObject:event];
    }

    NSMutableArray<NSString *> *previousWarningEvents = [NSMutableArray array];
    for (NSNumber *warning in previousWarnings) {
        NSString *event = [self warningNameWithNumber:warning];
        [previousWarningEvents addObject:event];
    }

    [self sendEventWithName:kTwilioVoiceReactNativeScopeCall
                       body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeCallEventQualityWarningsChanged,
                              kTwilioVoiceReactNativeEventKeyCall: [self callInfo:call],
                              kTwilioVoiceReactNativeCallEventCurrentWarnings: currentWarningEvents,
                              kTwilioVoiceReactNativeCallEventPreviousWarnings: previousWarningEvents}];
}

#pragma mark - Ringback

- (void)playRingback {
    NSString *ringtonePath = [[NSBundle mainBundle] pathForResource:@"ringtone" ofType:@"wav"];
    if ([ringtonePath length] <= 0) {
        NSLog(@"Can't find sound file");
        return;
    }

    NSError *error;
    self.ringbackPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL URLWithString:ringtonePath] error:&error];
    if (error != nil) {
        NSLog(@"Failed to initialize audio player: %@", error);
    } else {
        self.ringbackPlayer.delegate = self;
        self.ringbackPlayer.numberOfLoops = -1;

        self.ringbackPlayer.volume = 1.0f;
        [self.ringbackPlayer play];
    }
}

- (void)stopRingback {
    if (!self.ringbackPlayer.isPlaying) {
        return;
    }

    [self.ringbackPlayer stop];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (flag) {
        NSLog(@"Audio player finished playing successfully");
    } else {
        NSLog(@"Audio player finished playing with some error");
    }
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    NSLog(@"Decode error occurred: %@", error);
}

#pragma mark - Warning event conversion

- (NSString *)getSimplifiedISO8601FormattedTimestamp:(NSDate *)date {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    NSLocale *locale = [NSLocale currentLocale];
    [formatter setLocale:locale];
    [formatter setDateFormat:@"yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'SSSZ"];

    return [formatter stringFromDate:date];
}

- (nullable TVOIceOptions *)buildTVOIceOptionsWithServers:(nullable NSArray<NSDictionary *> *)jsIceServers
                                          transportPolicy:(nullable NSString *)jsIceTransportPolicy {
    NSMutableArray<TVOIceServer *> *nativeIceServers = [NSMutableArray new];
    for (NSDictionary *jsIceServer in jsIceServers) {
        NSString *password = [jsIceServer objectForKey:kTwilioVoiceReactNativeIceServerKeyPassword];
        NSString *username = [jsIceServer objectForKey:kTwilioVoiceReactNativeIceServerKeyUsername];
        NSString *serverUrl = [jsIceServer objectForKey:kTwilioVoiceReactNativeIceServerKeyServerUrl];

        if (serverUrl != nil && username != nil && password != nil) {
            TVOIceServer *nativeIceServer =
                [[TVOIceServer alloc] initWithURLString:serverUrl
                                               username:username
                                               password:password];
            [nativeIceServers addObject:nativeIceServer];
        } else if (serverUrl != nil) {
            TVOIceServer *nativeIceServer =
                [[TVOIceServer alloc] initWithURLString:serverUrl];
            [nativeIceServers addObject:nativeIceServer];
        }
    }

    const BOOL hasTransportPolicy =
        [jsIceTransportPolicy isEqualToString:kTwilioVoiceReactNativeIceTransportPolicyValueAll] ||
        [jsIceTransportPolicy isEqualToString:kTwilioVoiceReactNativeIceTransportPolicyValueRelay];

    if (nativeIceServers.count == 0 && !hasTransportPolicy) {
        return nil;
    }

    return [TVOIceOptions optionsWithBlock:^(TVOIceOptionsBuilder *builder) {
        if (nativeIceServers.count > 0) {
            builder.servers = nativeIceServers;
        }
        if ([jsIceTransportPolicy isEqualToString:kTwilioVoiceReactNativeIceTransportPolicyValueAll]) {
            builder.transportPolicy = TVOIceTransportPolicyAll;
        } else if ([jsIceTransportPolicy isEqualToString:kTwilioVoiceReactNativeIceTransportPolicyValueRelay]) {
            builder.transportPolicy = TVOIceTransportPolicyRelay;
        }
    }];
}

/**
 * VoxNote: ICE options for a call. Per-call options passed to `Voice.connect` /
 * `CallInvite.accept` (upstream 1.8) win; otherwise fall back to the generation-stamped
 * configuration cached through `voice_setIceConfiguration`, so natively answered calls
 * (CallKit, before JS is ready) still get TURN relays. Consumes the per-call entries.
 */
- (nullable TVOIceOptions *)voxnoteIceOptionsForUuid:(NSString *)uuidString
                             usedCachedConfiguration:(BOOL *)usedCachedConfiguration {
    NSArray<NSDictionary *> *perCallServers = self.iceServersMap[uuidString];
    NSString *perCallPolicy = self.iceTransportPolicyMap[uuidString];
    [self.iceServersMap removeObjectForKey:uuidString];
    [self.iceTransportPolicyMap removeObjectForKey:uuidString];
    if (usedCachedConfiguration) {
        *usedCachedConfiguration = NO;
    }
    if (perCallServers != nil || perCallPolicy != nil) {
        return [self buildTVOIceOptionsWithServers:perCallServers transportPolicy:perCallPolicy];
    }

    BOOL hasValidCachedIceConfiguration = self.iceExpiresAt == nil ||
        self.iceExpiresAt.doubleValue > [[NSDate date] timeIntervalSince1970] * 1000.0;
    NSArray<NSDictionary *> *cachedServers = hasValidCachedIceConfiguration ? self.iceServers : nil;
    TVOIceOptions *options = [self buildTVOIceOptionsWithServers:cachedServers
                                                 transportPolicy:self.iceTransportPolicy];
    if (options != nil && cachedServers.count > 0 && usedCachedConfiguration) {
        *usedCachedConfiguration = YES;
    }
    return options;
}

@end

