//
//  TwilioVoiceReactNative.m
//  TwilioVoiceReactNative
//
//  Copyright © 2022 Twilio, Inc. All rights reserved.
//

@import AVKit;
@import Security;

#import "TwilioVoicePushRegistry.h"
#import "TwilioVoiceReactNative.h"
#import "TwilioVoiceReactNativeConstants.h"
#import "TwilioVoiceStatsReport.h"

NSString * const kTwilioVoiceReactNativeVoiceError = @"Voice error";
dispatch_time_t const kPushRegistryDeviceTokenRetryTimeout = 3;
dispatch_time_t const kExponentialBackoff = 2;

// Call & call invite
NSString * const kTwilioVoiceReactNativeEventKeyCall = @"call";
NSString * const kTwilioVoiceReactNativeEventKeyCallInvite = @"callInvite";
NSString * const kTwilioVoiceReactNativeEventKeyCancelledCallInvite = @"cancelledCallInvite";

// Audio device
NSString * const kTwilioVoiceAudioDeviceUid = @"uid";

static TVODefaultAudioDevice *sTwilioAudioDevice;
static NSString * const kVoxNoteIceConfigurationKeychainService = @"com.voxnote.twilio.ice-configuration";
static NSString * const kVoxNoteCallAudioOwnershipKey = @"voxnote_call_audio_owned";

@import TwilioVoice;

#pragma mark - Custom AVRoutePickerView Implementation

@interface TVRNAVRoutePickerView : AVRoutePickerView

- (void)present;

@end

@implementation TVRNAVRoutePickerView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.hidden = YES;
    }

    return self;
}

- (void)present {
    UIButton *routePickerButton;
    for (id view in self.subviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            routePickerButton = (UIButton *)view;
            [routePickerButton sendActionsForControlEvents:UIControlEventTouchUpInside];
            break;
        }
    }
}

@end

#pragma mark - TwilioVoiceReactNative

@interface TwilioVoiceReactNative ()

@property (nonatomic, strong) TwilioVoicePushRegistry *twilioVoicePushRegistry;

@property(nonatomic, strong) NSData *deviceTokenData;
@property(nonatomic, strong) NSMutableDictionary *audioDevices;
@property(nonatomic, strong) NSDictionary *selectedAudioDevice;
@property(nonatomic, assign) BOOL registrationInProgress;
@property(nonatomic, assign) BOOL deviceTokenWasInvalidated;
@property(nonatomic, assign) NSUInteger deviceTokenGeneration;

- (void)loadPersistedIceConfiguration;
- (BOOL)applyIceConfiguration:(NSDictionary *)configuration persist:(BOOL)persist error:(NSError **)error;
- (BOOL)clearPersistedIceConfiguration:(NSError **)error;

- (void)registerWithAccessToken:(NSString *)accessToken
                 deviceTokenData:(NSData *)deviceTokenData
                        resolver:(RCTPromiseResolveBlock)resolver;

@end

@implementation TwilioVoiceReactNative {
    BOOL _hasObserver;
}

- (instancetype)init {
    if (self = [super init]) {
        _callMap = [NSMutableDictionary dictionary];
        _callConnectMap = [NSMutableDictionary dictionary];
        _callInviteMap = [NSMutableDictionary dictionary];
        _cancelledCallInviteMap = [NSMutableDictionary dictionary];
		_callIceGenerationMap = [NSMutableDictionary dictionary];
		_audioDevices = [NSMutableDictionary dictionary];
		_iceApplicationStatus = @"none";
		[self loadPersistedIceConfiguration];
		[self voxnoteSetCallAudioOwned:NO];

        NSString *reactNativeSDK = kTwilioVoiceReactNativeReactNativeVoiceSDK;
        setenv("global-env-sdk", [reactNativeSDK UTF8String], 1);

        NSString *reactNativeSdkVersion = kTwilioVoiceReactNativeReactNativeVoiceSDKVer;
        setenv("com.twilio.voice.env.sdk.version", [reactNativeSdkVersion UTF8String], 1);

        sTwilioAudioDevice = [TVODefaultAudioDevice audioDevice];
        TwilioVoiceSDK.audioDevice = sTwilioAudioDevice;

        TwilioVoiceSDK.logLevel = TVOLogLevelTrace;

        [self subscribeToNotifications];
        [self initializePushRegistry];
        [self initializeCallKit];
        [self initializeAudioDeviceList];
    }

	return self;
}

- (void)voxnoteSetCallAudioOwned:(BOOL)owned {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:owned forKey:kVoxNoteCallAudioOwnershipKey];
}

- (void)voxnoteRefreshCallAudioOwnership {
    [self voxnoteSetCallAudioOwned:(self.callMap.count > 0 || self.callInviteMap.count > 0)];
}

- (void)loadPersistedIceConfiguration {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kVoxNoteIceConfigurationKeychainService,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || result == NULL) return;

    NSData *data = CFBridgingRelease(result);
    NSDictionary *configuration = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSError *error = nil;
    if (![configuration isKindOfClass:[NSDictionary class]] ||
        ![self applyIceConfiguration:configuration persist:NO error:&error]) {
        [self clearPersistedIceConfiguration:nil];
    }
}

- (BOOL)applyIceConfiguration:(NSDictionary *)configuration persist:(BOOL)persist error:(NSError **)error {
    NSString *generationId = configuration[@"generationId"];
    NSArray *servers = configuration[@"iceServers"];
    NSNumber *expiresAt = configuration[@"expiresAt"];
    NSNumber *attemptedAt = @([[NSDate date] timeIntervalSince1970] * 1000.0);
    self.iceAttemptedAt = attemptedAt;

    BOOL valid = [generationId isKindOfClass:[NSString class]] && generationId.length > 0 &&
        [servers isKindOfClass:[NSArray class]] && servers.count > 0 &&
        [expiresAt isKindOfClass:[NSNumber class]] && expiresAt.doubleValue > attemptedAt.doubleValue;
    if (valid) {
        for (NSDictionary *server in servers) {
            if (![server isKindOfClass:[NSDictionary class]] ||
                ![server[kTwilioVoiceReactNativeIceServerKeyServerUrl] isKindOfClass:[NSString class]] ||
                [server[kTwilioVoiceReactNativeIceServerKeyServerUrl] length] == 0) {
                valid = NO;
                break;
            }
        }
    }

    if (!valid) {
        self.iceApplicationStatus = @"failed";
        self.iceApplicationErrorCode = @"invalid_configuration";
        if (error) {
            *error = [NSError errorWithDomain:@"TwilioVoiceReactNativeIceConfiguration"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid or expired ICE configuration"}];
        }
        return NO;
    }

    if (persist) {
        NSDictionary *persisted = @{
            @"generationId": generationId,
            @"iceServers": servers,
            @"expiresAt": expiresAt,
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:persisted options:0 error:error];
        if (!data) return NO;
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kVoxNoteIceConfigurationKeychainService,
        };
        OSStatus keychainStatus = SecItemUpdate(
            (__bridge CFDictionaryRef)query,
            (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data}
        );
        if (keychainStatus == errSecItemNotFound) {
            NSDictionary *attributes = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kVoxNoteIceConfigurationKeychainService,
            (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            (__bridge id)kSecValueData: data,
            };
            keychainStatus = SecItemAdd((__bridge CFDictionaryRef)attributes, NULL);
        }
        if (keychainStatus != errSecSuccess) {
            self.iceApplicationStatus = @"failed";
            self.iceApplicationErrorCode = [NSString stringWithFormat:@"keychain_%d", (int)keychainStatus];
            if (error) {
                *error = [NSError errorWithDomain:@"TwilioVoiceReactNativeIceConfiguration"
                                             code:keychainStatus
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to persist ICE configuration"}];
            }
            return NO;
        }
    }

    self.iceServers = servers;
    self.iceTransportPolicy = nil;
    self.iceGenerationId = generationId;
    self.iceExpiresAt = expiresAt;
    self.iceAppliedAt = @([[NSDate date] timeIntervalSince1970] * 1000.0);
    self.iceApplicationStatus = @"applied";
    self.iceApplicationErrorCode = nil;
    return YES;
}

- (BOOL)clearPersistedIceConfiguration:(NSError **)error {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kVoxNoteIceConfigurationKeychainService,
    };
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status == errSecSuccess || status == errSecItemNotFound) {
        return YES;
    }
    self.iceApplicationStatus = @"failed";
    self.iceApplicationErrorCode = [NSString stringWithFormat:@"keychain_delete_%d", (int)status];
    if (error) {
        *error = [NSError errorWithDomain:@"TwilioVoiceReactNativeIceConfiguration"
                                     code:status
                                 userInfo:@{NSLocalizedDescriptionKey: @"Failed to clear persisted ICE configuration"}];
    }
    return NO;
}

- (void)initializePushRegistry {
    if (self.twilioVoicePushRegistry != nil) {
        return;
    }

    self.twilioVoicePushRegistry = [TwilioVoicePushRegistry new];
    [self.twilioVoicePushRegistry updatePushRegistry];
}

- (void)subscribeToNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePushRegistryNotification:)
                                                 name:kTwilioVoicePushRegistryNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handlePushRegistryNotification:(NSNotification *)notification {
    NSMutableDictionary *eventBody = [notification.userInfo mutableCopy];
    NSString *type = eventBody[kTwilioVoiceReactNativeVoiceEventType];
    if ([type isEqualToString:kTwilioVoicePushRegistryNotificationDeviceTokenUpdated]) {
        NSData *updatedDeviceTokenData = eventBody[kTwilioVoicePushRegistryNotificationDeviceToken];
        BOOL recoveringFromInvalidation = self.deviceTokenWasInvalidated;
        BOOL tokenChanged = self.deviceTokenData != nil && ![self.deviceTokenData isEqualToData:updatedDeviceTokenData];
        BOOL credentialsChanged = tokenChanged || recoveringFromInvalidation;
        if (credentialsChanged) {
            self.deviceTokenGeneration += 1;
        }
        self.deviceTokenData = updatedDeviceTokenData;
        self.deviceTokenWasInvalidated = NO;

        if (credentialsChanged && [self.accessToken length] > 0) {
            if (self.registrationInProgress) {
                NSLog(@"[TwilioVoiceReactNative] VoIP token changed or recovered while registration is already in progress; the stale attempt will refresh.");
            } else {
                NSLog(@"[TwilioVoiceReactNative] VoIP token changed or recovered; refreshing Twilio registration.");
                [self registerWithAccessToken:self.accessToken
                              deviceTokenData:updatedDeviceTokenData
                                     resolver:nil];
            }
        }

        // Skip the event emitting since 1, the listener has not registered and 2, the app does not need to know about this
        return;
    } else if ([type isEqualToString:kTwilioVoicePushRegistryNotificationDeviceTokenInvalidated]) {
        self.deviceTokenGeneration += 1;
        self.deviceTokenData = nil;
        self.deviceTokenWasInvalidated = YES;

        NSLog(@"[TwilioVoiceReactNative] VoIP token invalidated; cached token cleared while awaiting replacement credentials.");
        [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice
                           body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventUnregistered}];
        return;
    } else if ([type isEqualToString:kTwilioVoicePushRegistryNotificationIncomingPushReceived]) {
        NSDictionary *payload = eventBody[kTwilioVoicePushRegistryNotificationIncomingPushPayload];
        [TwilioVoiceSDK handleNotification:payload delegate:self delegateQueue:nil callMessageDelegate:self];
    }
}

+ (TVODefaultAudioDevice *)twilioAudioDevice {
    return sTwilioAudioDevice;
}

- (void)handleRouteChange:(NSNotification *)notification {
    // Dispatch to a background queue to avoid blocking the main thread.
    // AVAudioSession.availableInputs can trigger a synchronous XPC call
    // that hangs the main thread for 2+ seconds.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self availableAudioDevices];

        NSMutableArray *nativeAudioDeviceInfos = [NSMutableArray array];
        for (NSString *key in [self.audioDevices allKeys]) {
            [nativeAudioDeviceInfos addObject:self.audioDevices[key]];
        }

        NSMutableDictionary *eventBody = [@{
            kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventAudioDevicesUpdated,
            kTwilioVoiceReactNativeAudioDeviceKeyAudioDevices: nativeAudioDeviceInfos
        } mutableCopy];

        if (self.selectedAudioDevice != nil) {
            eventBody[kTwilioVoiceReactNativeAudioDeviceKeySelectedDevice] = self.selectedAudioDevice;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:eventBody];
        });
    });
}

- (void)initializeAudioDeviceList {
    NSUUID *receiverUuid = [NSUUID UUID];
    NSDictionary *builtInReceiver = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: receiverUuid.UUIDString,
                                       kTwilioVoiceReactNativeAudioDeviceKeyType: kTwilioVoiceReactNativeAudioDeviceKeyEarpiece,
                                       kTwilioVoiceReactNativeAudioDeviceKeyName: @"iPhone",
                                       kTwilioVoiceAudioDeviceUid: AVAudioSessionPortBuiltInReceiver};
    self.audioDevices[receiverUuid.UUIDString] = builtInReceiver;

    NSUUID *speakerUuid = [NSUUID UUID];
    NSDictionary *builtInSpeaker = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: speakerUuid.UUIDString,
                                      kTwilioVoiceReactNativeAudioDeviceKeyType: kTwilioVoiceReactNativeAudioDeviceKeySpeaker,
                                      kTwilioVoiceReactNativeAudioDeviceKeyName: @"Speaker",
                                      kTwilioVoiceAudioDeviceUid: AVAudioSessionPortBuiltInSpeaker};
    self.audioDevices[speakerUuid.UUIDString] = builtInSpeaker;

    [self availableAudioDevices];
}

- (NSDictionary *)availableAudioDevices {
    // Pop all except the built-in earpiece and speaker
    for (NSString *key in [self.audioDevices allKeys]) {
        NSDictionary *audioDevice = self.audioDevices[key];
        if (![audioDevice[kTwilioVoiceAudioDeviceUid] isEqualToString:AVAudioSessionPortBuiltInReceiver] &&
            ![audioDevice[kTwilioVoiceAudioDeviceUid] isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            [self.audioDevices removeObjectForKey:key];
        }
    }

    NSLog(@"Available audio input devices");
    NSArray *availableInputs = [[AVAudioSession sharedInstance] availableInputs];
    for (AVAudioSessionPortDescription *port in availableInputs) {
        NSLog(@"\t%@, %@, %@", port.portType, port. portName, port.UID);

        if ([port.portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
            NSUUID *uuid = [NSUUID UUID];
            NSDictionary *bluetoothHfpDevice = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: uuid.UUIDString,
                                                  kTwilioVoiceReactNativeAudioDeviceKeyType: [self audioPortTypeMapping:port.portType],
                                                  kTwilioVoiceReactNativeAudioDeviceKeyName: port.portName,
                                                  kTwilioVoiceAudioDeviceUid: port.UID };
            self.audioDevices[uuid.UUIDString] = bluetoothHfpDevice;
        }
    }

    NSLog(@"Current route, inputs");
    AVAudioSessionRouteDescription *currentRoute = [[AVAudioSession sharedInstance] currentRoute];
    NSArray *inputs = currentRoute.inputs;
    for (AVAudioSessionPortDescription *port in inputs) {
        NSLog(@"\t%@, %@, %@", port.portType, port.portName, port.UID);
    }

    NSLog(@"Current route, outputs");
    NSArray *outputs = currentRoute.outputs;
    for (AVAudioSessionPortDescription *port in outputs) {
        NSLog(@"\t%@, %@, %@", port.portType, port.portName, port.UID);

        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
            for (NSString *key in [self.audioDevices allKeys]) {
                NSDictionary *device = self.audioDevices[key];
                if ([device[kTwilioVoiceReactNativeAudioDeviceKeyType] isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeyEarpiece]) {
                    self.selectedAudioDevice = device;
                    break;
                }
            }
        } else if ([port.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
            for (NSString *key in [self.audioDevices allKeys]) {
                NSDictionary *device = self.audioDevices[key];
                if ([device[kTwilioVoiceReactNativeAudioDeviceKeyType] isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeySpeaker]) {
                    self.selectedAudioDevice = device;
                }
            }
        } else {
            BOOL found = NO;
            for (NSString *key in [self.audioDevices allKeys]) {
                NSDictionary *device = self.audioDevices[key];
                if ([device[kTwilioVoiceAudioDeviceUid] isEqualToString:port.UID]) {
                    found = YES;
                    self.selectedAudioDevice = device;
                    break;
                }
            }

            if (!found) {
                NSLog(@"Unidentified output device selected: %@, %@, %@", port.portType, port.portName, port.UID);
                NSUUID *uuid = [NSUUID UUID];
                NSDictionary *unidentifiedDevice = @{ kTwilioVoiceReactNativeAudioDeviceKeyUuid: uuid.UUIDString,
                                                      kTwilioVoiceReactNativeAudioDeviceKeyType: [self audioPortTypeMapping:port.portType],
                                                      kTwilioVoiceReactNativeAudioDeviceKeyName: port.portName,
                                                      kTwilioVoiceAudioDeviceUid: port.UID };
                self.audioDevices[uuid.UUIDString] = unidentifiedDevice;
                self.selectedAudioDevice = unidentifiedDevice;
            }
        }
    }

    return self.audioDevices;
}

- (NSString *)audioPortTypeMapping:(NSString *)portType {
    if ([portType isEqualToString:AVAudioSessionPortBuiltInReceiver]) {
        return kTwilioVoiceReactNativeAudioDeviceKeyEarpiece;
    } else if ([portType isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
        return kTwilioVoiceReactNativeAudioDeviceKeySpeaker;
    } else if ([portType isEqualToString:AVAudioSessionPortBluetoothHFP]) {
        return kTwilioVoiceReactNativeAudioDeviceKeyBluetooth;
    }

    return portType;
}

- (BOOL)selectAudioDevice:(NSString *)uuid {
    if (!self.audioDevices[uuid]) {
        NSLog(@"No matching audio device found for %@", uuid);
        return NO;
    }

    NSDictionary *device = self.audioDevices[uuid];
    NSString *portUid = device[kTwilioVoiceAudioDeviceUid];
    NSString *portType = device[kTwilioVoiceReactNativeAudioDeviceKeyType];

    NSLog(@"Selecting %@(%@), %@", device[kTwilioVoiceReactNativeAudioDeviceKeyName], device[kTwilioVoiceReactNativeAudioDeviceKeyType], device[kTwilioVoiceAudioDeviceUid]);

    AVAudioSessionPortDescription *portDescription = nil;
    if ([portType isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeyEarpiece]) {
        NSArray *availableInputs = [[AVAudioSession sharedInstance] availableInputs];
        for (AVAudioSessionPortDescription *port in availableInputs) {
            if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                portDescription = port;
                break;
            }
        }

        if (!portDescription) {
            NSLog(@"Built-in mic not found");
            return NO;
        }
    } else if ([portType isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeyBluetooth]) {
        NSArray *availableInputs = [[AVAudioSession sharedInstance] availableInputs];
        for (AVAudioSessionPortDescription *port in availableInputs) {
            if ([port.UID isEqualToString:portUid]) {
                portDescription = port;
                break;
            }
        }

        if (!portDescription) {
            NSLog(@"Bluetooth device %@ not found", device[kTwilioVoiceReactNativeAudioDeviceKeyName]);
            return NO;
        }
    }

    // Update preferred input
    NSError *inputError;
    [[AVAudioSession sharedInstance] setPreferredInput:portDescription error:&inputError];
    if (inputError) {
        NSLog(@"Failed to set preferred input: %@", inputError);
        return NO;
    }

    // Override output to speaker if speaker is selected
    if ([portType isEqualToString:kTwilioVoiceReactNativeAudioDeviceKeySpeaker]) {
        AVAudioSessionPortOverride outputOverride = AVAudioSessionPortOverrideSpeaker;
        NSError *outputError;
        [[AVAudioSession sharedInstance] overrideOutputAudioPort:outputOverride error:&outputError];
        if (outputError) {
            NSLog(@"Failed to override output port: %@", outputError);
            return NO;
        }
    }

    return YES;
}

// TODO: Move to separate utility file someday
- (NSDictionary *)callInfo:(TVOCall *)call {
    NSMutableDictionary *callInfo = [@{kTwilioVoiceReactNativeCallInfoIsMuted: @(call.isMuted),
                                       kTwilioVoiceReactNativeCallInfoIsOnHold: @(call.isOnHold),
                                       kTwilioVoiceReactNativeCallInfoSid: call.sid,
                                       kTwilioVoiceReactNativeCallInfoState: [self stringOfState:call.state]} mutableCopy];

    if (call.uuid != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoUuid] = call.uuid.UUIDString;
    }

    if (call.from != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoFrom] = call.from;
    }

    if (call.to != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoTo] = call.to;
    }

    NSString *initialConnectedTimestamp = self.callConnectMap[call.uuid.UUIDString];
    if (initialConnectedTimestamp != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoInitialConnectedTimestamp] = initialConnectedTimestamp;
    }

    NSString *iceGenerationId = self.callIceGenerationMap[call.uuid.UUIDString];
    if (iceGenerationId != nil) {
        callInfo[kTwilioVoiceReactNativeCallInfoIceGenerationId] = iceGenerationId;
    }

    TVOCallInvite *callInvite = self.callInviteMap[call.uuid.UUIDString];
    if (callInvite && callInvite.customParameters) {
        callInfo[kTwilioVoiceReactNativeCallInviteInfoCustomParameters] = [callInvite.customParameters copy];
    }

    return callInfo;
}

- (NSDictionary *)callInviteInfo:(TVOCallInvite *)callInvite {
    NSMutableDictionary *callInviteInfo = [@{kTwilioVoiceReactNativeCallInviteInfoUuid: callInvite.uuid.UUIDString,
                                             kTwilioVoiceReactNativeCallInviteInfoCallSid: callInvite.callSid,
                                             kTwilioVoiceReactNativeCallInviteInfoTo: callInvite.to} mutableCopy];

    if (callInvite.from != nil) {
        callInviteInfo[kTwilioVoiceReactNativeCallInviteInfoFrom] = callInvite.from;
    }

    if (callInvite.customParameters != nil) {
        callInviteInfo[kTwilioVoiceReactNativeCallInviteInfoCustomParameters] = [callInvite.customParameters copy];
    }

    NSString *iceGenerationId = self.callIceGenerationMap[callInvite.uuid.UUIDString];
    if (iceGenerationId != nil) {
        callInviteInfo[kTwilioVoiceReactNativeCallInfoIceGenerationId] = iceGenerationId;
    }

    return callInviteInfo;
}

- (NSDictionary *)cancelledCallInviteInfo:(TVOCancelledCallInvite *)cancelledCallInvite {
    NSMutableDictionary *cancelledCallInviteInfo = [@{
        kTwilioVoiceReactNativeCancelledCallInviteInfoCallSid: cancelledCallInvite.callSid,
        kTwilioVoiceReactNativeCancelledCallInviteInfoTo: cancelledCallInvite.to
    } mutableCopy];

    if (cancelledCallInvite.from != nil) {
        cancelledCallInviteInfo[kTwilioVoiceReactNativeCancelledCallInviteInfoFrom] = cancelledCallInvite.from;
    }

    if (cancelledCallInvite.customParameters != nil) {
        cancelledCallInviteInfo[kTwilioVoiceReactNativeCancelledCallInviteInfoCustomParameters] = [cancelledCallInvite.customParameters copy];
    }

    return cancelledCallInviteInfo;
}

RCT_EXPORT_MODULE();

#pragma mark - React Native

- (NSArray<NSString *> *)supportedEvents
{
    return @[kTwilioVoiceReactNativeScopeVoice, kTwilioVoiceReactNativeScopeCall, kTwilioVoiceReactNativeScopeCallInvite, kTwilioVoiceReactNativeScopeCallMessage, kTwilioVoiceReactNativeScopePreflightTest];
}

+ (BOOL)requiresMainQueueSetup
{
    return YES;
}

- (void)startObserving {
    NSLog(@"Started observing");
    _hasObserver = YES;
}

- (void)stopObserving {
    NSLog(@"Stopped observing");
    _hasObserver = NO;
}

- (void)sendEventWithName:(NSString *)eventName body:(id)body {
    if (_hasObserver) {
        [super sendEventWithName:eventName body:body];
    } else {
        NSLog(@"No event observer registered yet. Omitting event: %@, event body: %@", eventName, body);
    }
}

#pragma mark - Bindings (Voice methods)

RCT_EXPORT_METHOD(voice_getVersion:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self resolvePromise:resolver value:TwilioVoiceSDK.sdkVersion];
}

// VoxNote patch: read-only probe of the audio capture state at call time, so JS can
// emit a Sentry event and prove whether the audio unit is actually running on a
// connected call. See tasks/silent-call-fix-spec.md (PR 3 instrumentation).
RCT_EXPORT_METHOD(voice_getAudioDeviceState:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    TVODefaultAudioDevice *device = [TwilioVoiceReactNative twilioAudioDevice];
    [self resolvePromise:resolver value:@{
        @"enabled": @(device.enabled),
        @"category": session.category ?: @"",
        @"mode": session.mode ?: @"",
        @"isOtherAudioPlaying": @(session.isOtherAudioPlaying),
        @"secondaryAudioShouldBeSilencedHint": @(session.secondaryAudioShouldBeSilencedHint)
    }];
}

RCT_EXPORT_METHOD(voice_setCallAudioOwnership:(BOOL)owned
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    if (owned) {
        [self voxnoteSetCallAudioOwned:YES];
    } else {
        [self voxnoteRefreshCallAudioOwnership];
    }
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_getDeviceToken:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    if (self.deviceTokenData) {
        const char *tokenBytes = (const char *)[self.deviceTokenData bytes];
        NSMutableString *deviceTokenString = [NSMutableString string];
        for (NSUInteger i = 0; i < [self.deviceTokenData length]; ++i) {
            [deviceTokenString appendFormat:@"%02.2hhx", tokenBytes[i]];
        }
        [self resolvePromise:resolver value:deviceTokenString];
    } else {
        [self resolvePromise:resolver value:@""];
    }
}

RCT_EXPORT_METHOD(voice_initializePushRegistry:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self initializePushRegistry];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_setCallKitConfiguration:(NSDictionary *)configuration
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self initializeCallKitWithConfiguration:configuration];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_register:(NSString *)accessToken
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
#if TARGET_IPHONE_SIMULATOR
    if (!self.deviceTokenData) {
        NSLog(@"Please note that PushKit and incoming call are not supported on simulators");
        NSString *testDeviceToken = @"deadbeefdeadbeefdeadbeefdeadbeef";
        self.deviceTokenData = [testDeviceToken dataUsingEncoding:NSUTF8StringEncoding];
    }
#endif

    if (self.registrationInProgress) {
        NSString *errorMessage = @"Registration in progress. Please try again later";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
        return;
    }

    self.registrationInProgress = YES;

    [self asyncPushRegistryInitialization:kPushRegistryDeviceTokenRetryTimeout
                               completion:^(NSData *deviceTokenData) {
        if (deviceTokenData) {
            [self registerWithAccessToken:accessToken
                          deviceTokenData:deviceTokenData
                                 resolver:resolver];
        } else {
            self.registrationInProgress = NO;
            [self rejectPromiseWithName:resolver
                name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                message:@"Failed to initialize PushKit device token"
            ];
        }
    }];
}

- (void)registerWithAccessToken:(NSString *)accessToken
                 deviceTokenData:(NSData *)deviceTokenData
                        resolver:(RCTPromiseResolveBlock)resolver {
    self.registrationInProgress = YES;
    NSUInteger registrationDeviceTokenGeneration = self.deviceTokenGeneration;

    [TwilioVoiceSDK registerWithAccessToken:accessToken
                                deviceToken:deviceTokenData
                                 completion:^(NSError *error) {
        BOOL staleRegistration =
            registrationDeviceTokenGeneration != self.deviceTokenGeneration ||
            self.deviceTokenData == nil ||
            ![self.deviceTokenData isEqualToData:deviceTokenData];
        self.registrationInProgress = NO;

        if (staleRegistration) {
            self.accessToken = accessToken;

            NSString *errorMessage = @"PushKit device token changed or was invalidated while Twilio registration was in progress";
            NSLog(@"[TwilioVoiceReactNative] %@; ignoring stale registration result.", errorMessage);
            [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice
                               body:@{kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventUnregistered}];

            if (self.deviceTokenData != nil && [accessToken length] > 0) {
                [self registerWithAccessToken:accessToken
                              deviceTokenData:self.deviceTokenData
                                     resolver:resolver];
            } else if (resolver) {
                [self rejectPromiseWithName:resolver
                                       name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                                    message:errorMessage];
            }
            return;
        }

        if (error) {
            NSString *errorMessage = [error localizedDescription];
            NSNumber *errorCode = @(error.code);

            NSDictionary *payload = @{
                kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventError,
                kTwilioVoiceReactNativeVoiceErrorKeyError: @{
                    kTwilioVoiceReactNativeVoiceErrorKeyCode: errorCode,
                    kTwilioVoiceReactNativeVoiceErrorKeyMessage: errorMessage
                }
            };
            [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];

            if (resolver) {
                [self rejectPromiseWithCode:resolver code:errorCode message:errorMessage];
            }
        } else {
            self.accessToken = accessToken;

            NSDictionary *payload = @{
                kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventRegistered
            };
            [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];

            if (resolver) {
                [self resolvePromise:resolver value:[NSNull null]];
            }
        }
    }];
}

- (void)asyncPushRegistryInitialization:(dispatch_time_t)timeout
                             completion:(void(^)(NSData *deviceTokenData))completion {
    if (self.deviceTokenData) {
        completion(self.deviceTokenData);
        return;
    }

    if (timeout > 0) {
        __block dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_after(delay, dispatch_get_main_queue(), ^{
            dispatch_time_t backoffTimeout = (timeout > kExponentialBackoff)? timeout - kExponentialBackoff : 0;
            [weakSelf asyncPushRegistryInitialization:backoffTimeout completion:completion];
        });
    } else {
        // Device token could be nil. The voice_register() method will handle the promise.
        completion(self.deviceTokenData);
    }
}

RCT_EXPORT_METHOD(voice_unregister:(NSString *)accessToken
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
#if TARGET_IPHONE_SIMULATOR
    if (!self.deviceTokenData) {
        NSLog(@"Please note that PushKit and incoming call are not supported on simulators");
        NSString *testDeviceToken = @"deadbeefdeadbeefdeadbeefdeadbeef";
        self.deviceTokenData = [testDeviceToken dataUsingEncoding:NSUTF8StringEncoding];
    }
#endif

    if (self.registrationInProgress) {
        NSString *errorMessage = @"Registration in progress. Please try again later";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
        return;
    }

    // Disable automatic token refresh as soon as an explicit unregister begins.
    // A failed unregister must not allow a later PushKit update to re-register
    // the user with the cached access token.
    self.accessToken = nil;
    self.registrationInProgress = YES;

    [self asyncPushRegistryInitialization:kPushRegistryDeviceTokenRetryTimeout
                               completion:^(NSData *deviceTokenData) {
        if (deviceTokenData) {
            [TwilioVoiceSDK unregisterWithAccessToken:accessToken
                                          deviceToken:deviceTokenData
                                           completion:^(NSError *error) {
                self.registrationInProgress = NO;
                if (error) {
                    NSString *errorMessage = [error localizedDescription];
                    NSNumber *errorCode = @(error.code);
                    
                    NSDictionary *payload = @{
                        kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventError,
                        kTwilioVoiceReactNativeVoiceErrorKeyError: @{
                            kTwilioVoiceReactNativeVoiceErrorKeyCode: errorCode,
                            kTwilioVoiceReactNativeVoiceErrorKeyMessage: errorMessage
                        }
                    };
                    
                    [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];
                    [self rejectPromiseWithCode:resolver code:errorCode message:errorMessage];
                } else {
                    NSDictionary *payload = @{
                        kTwilioVoiceReactNativeVoiceEventType: kTwilioVoiceReactNativeVoiceEventUnregistered
                    };
                    [self sendEventWithName:kTwilioVoiceReactNativeScopeVoice body:payload];
                    [self resolvePromise:resolver value:[NSNull null]];
                }
            }];
        } else {
            self.registrationInProgress = NO;
            
            NSString *errorMessage = @"Failed to initialize PushKit device token";
            [self rejectPromiseWithName:resolver
                name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                message:errorMessage
            ];
        }
    }];
}

RCT_EXPORT_METHOD(voice_connect_ios:(NSString *)accessToken
                  params:(NSDictionary *)params
                  contactHandle:(NSString *)contactHandle
                  iceServers:(NSArray<NSDictionary *> * _Nullable)iceServers
                  iceTransportPolicy:(NSString * _Nullable)iceTransportPolicy
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    if (self.callPromiseResolver != nil) {
        [self rejectPromiseWithName:resolver
                               name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
                            message:@"Another outbound call is already being started"];
        return;
    }

    // Store the resolver before requesting the CallKit transaction. A rejected
    // transaction may complete before makeCallWithAccessToken returns.
    self.callPromiseResolver = resolver;
    [self makeCallWithAccessToken:accessToken 
                           params:params 
                    contactHandle:contactHandle
                       iceServers:iceServers
               iceTransportPolicy:iceTransportPolicy];
}

RCT_EXPORT_METHOD(voice_setIceServers:(NSArray *)iceServers
                  iceTransportPolicy:(NSString *)iceTransportPolicy
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    self.iceServers = iceServers;
    self.iceTransportPolicy = iceTransportPolicy;
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_setIceConfiguration:(NSDictionary *)configuration
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        if ([self applyIceConfiguration:configuration persist:YES error:&error]) {
            [self resolvePromise:resolver value:[NSNull null]];
        } else {
            rejecter(@"ice_configuration_failed", error.localizedDescription, error);
        }
    });
}

RCT_EXPORT_METHOD(voice_getIceConfigurationState:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSNumber *now = @([[NSDate date] timeIntervalSince1970] * 1000.0);
    BOOL isValid = self.iceServers.count > 0 && self.iceExpiresAt.doubleValue > now.doubleValue;
    if (!isValid && self.iceServers.count > 0) {
        self.iceServers = nil;
        self.iceGenerationId = nil;
        self.iceExpiresAt = nil;
        self.iceApplicationStatus = @"none";
        [self clearPersistedIceConfiguration:nil];
    }
    [self resolvePromise:resolver value:@{
        @"generationId": self.iceGenerationId ?: [NSNull null],
        @"serverCount": @(self.iceServers.count),
        @"expiresAt": self.iceExpiresAt ?: [NSNull null],
        @"policy": @"all",
        @"isValid": @(isValid),
        @"status": self.iceApplicationStatus ?: @"none",
        @"attemptedAt": self.iceAttemptedAt ?: [NSNull null],
        @"appliedAt": self.iceAppliedAt ?: [NSNull null],
        @"errorCode": self.iceApplicationErrorCode ?: [NSNull null],
    }];
}

RCT_EXPORT_METHOD(voice_clearIceConfiguration:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    self.iceServers = nil;
    self.iceTransportPolicy = nil;
    self.iceGenerationId = nil;
    self.iceExpiresAt = nil;
    self.iceApplicationStatus = @"none";
    self.iceApplicationErrorCode = nil;
    NSError *error = nil;
    if ([self clearPersistedIceConfiguration:&error]) {
        [self resolvePromise:resolver value:[NSNull null]];
    } else {
        rejecter(@"ice_configuration_clear_failed", error.localizedDescription, error);
    }
}

RCT_EXPORT_METHOD(voice_getCalls:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSMutableArray *callInfoArray = [NSMutableArray array];
    for (NSString *uuid in [self.callMap allKeys]) {
        TVOCall *call = self.callMap[uuid];
        [callInfoArray addObject:[self callInfo:call]];
    }
    [self resolvePromise:resolver value:callInfoArray];
}

RCT_EXPORT_METHOD(voice_getCallInvites:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSMutableArray *callInviteInfoArray = [NSMutableArray array];
    for (NSString *uuid in [self.callInviteMap allKeys]) {
        TVOCallInvite *callInvite = self.callInviteMap[uuid];
        [callInviteInfoArray addObject:[self callInviteInfo:callInvite]];
    }
    [self resolvePromise:resolver value:callInviteInfoArray];
}

RCT_EXPORT_METHOD(voice_getAudioDevices:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSMutableArray *nativeAudioDeviceInfos = [NSMutableArray array];
    for (NSString *key in [self.audioDevices allKeys]) {
        [nativeAudioDeviceInfos addObject:self.audioDevices[key]];
    }
    NSDictionary *payload = @{
        kTwilioVoiceReactNativeAudioDeviceKeyAudioDevices: nativeAudioDeviceInfos,
        kTwilioVoiceReactNativeAudioDeviceKeySelectedDevice: self.selectedAudioDevice
    };
    [self resolvePromise:resolver value:payload];
}

RCT_EXPORT_METHOD(voice_selectAudioDevice:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    if ([self selectAudioDevice:uuid]) {
        [self resolvePromise:resolver value:[NSNull null]];
    } else {
        NSString *errorMessage = [NSString stringWithFormat:@"Failed to select audio device %@", uuid];
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
    }
}

RCT_EXPORT_METHOD(voice_showNativeAvRoutePicker:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVRNAVRoutePickerView *routePicker = [[TVRNAVRoutePickerView alloc] initWithFrame:CGRectZero];

    UIWindow *window = [UIApplication sharedApplication].windows[0];
    UIViewController *rootViewController = window.rootViewController;
    if (rootViewController) {
        UIViewController *topViewController = rootViewController;
        while (topViewController.presentedViewController) {
            topViewController = topViewController.presentedViewController;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [topViewController.view addSubview:routePicker];
            [routePicker present];
        });
    }

    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_setExpoVersion:(NSString *)expoVersion
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    if ([expoVersion length] > 0) {
        setenv("com.twilio.voice.env.sdk.expo_version", [expoVersion UTF8String], 1);
    } else {
        unsetenv("com.twilio.voice.env.sdk.expo_version");
    }
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(voice_setIncomingCallContactHandleTemplate:(NSString *)template
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    NSUserDefaults *preferences = [NSUserDefaults standardUserDefaults];
    NSString *preferenceKey = @"incomingCallContactHandleTemplate";
    [preferences setObject:template forKey:preferenceKey];
    [preferences synchronize];
    [self resolvePromise:resolver value:[NSNull null]];
}

#pragma mark - Bindings (Call)

- (TVOCall *)getCallFromMap:(NSString *)uuid resolver:(RCTPromiseResolveBlock)resolver {
    TVOCall *call = self.callMap[uuid];
    
    if (!call) {
        NSString *errorMessage = [NSString stringWithFormat:@"Call with uuid '%@' not found", uuid];
        [self rejectPromiseWithName:resolver
            name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
            message:errorMessage
        ];
        return nil;
    }
    
    return call;
}

RCT_EXPORT_METHOD(call_disconnect:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [self endCallWithUuid:[[NSUUID alloc] initWithUUIDString:uuid]];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(call_getState:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *state = [self stringOfState:call.state];
    [self resolvePromise:resolver value:state];
}

RCT_EXPORT_METHOD(call_getSid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *callSid = call.state != TVOCallStateConnecting ? call.sid : @"";
    [self resolvePromise:resolver value:callSid];
}

RCT_EXPORT_METHOD(call_getFrom:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *from = [call.from length] > 0 ? call.from : @"";
    [self resolvePromise:resolver value:from];
}

RCT_EXPORT_METHOD(call_getTo:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    NSString *to = [call.to length] > 0 ? call.to : @"";
    [self resolvePromise:resolver value:to];
}

RCT_EXPORT_METHOD(call_hold:(NSString *)uuid
                  onHold:(BOOL)onHold
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call setOnHold:onHold];
    [self resolvePromise:resolver value:@(call.isOnHold)];
}

RCT_EXPORT_METHOD(call_isOnHold:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [self resolvePromise:resolver value:@(call.isOnHold)];
}

RCT_EXPORT_METHOD(call_mute:(NSString *)uuid
                  muted:(BOOL)muted
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call setMuted:muted];
    [self resolvePromise:resolver value:@(call.isMuted)];
}

RCT_EXPORT_METHOD(call_isMuted:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [self resolvePromise:resolver value:@(call.isMuted)];
}

RCT_EXPORT_METHOD(call_sendDigits:(NSString *)uuid
                  digits:(NSString *)digits
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call sendDigits:digits];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(call_postFeedback:(NSString *)uuid
                  score:(NSString *)score
                  issue:(NSString *)issue
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call postFeedback:[self scoreFromString:score] issue:[self issueFromString:issue]];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(call_getStats:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCall *call = [self getCallFromMap:uuid resolver:resolver];
    if (!call) return;
    
    [call getStatsWithBlock:^(NSArray<TVOStatsReport *> *statsReports) {
        NSAssert([statsReports count] >= 1, @"Invalid stats reports array size");
        NSArray *statsReportJson = [TwilioVoiceStatsReport jsonWithStatsReportsArray:statsReports];
        [self resolvePromise:resolver value:statsReportJson];
    }];
}

RCT_EXPORT_METHOD(call_sendMessage:(NSString *)uuid
                  content:(NSString *)content
                  contentType:(NSString *)contentType
                  messageType:(NSString *)messageType
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = self.callInviteMap[uuid];
    TVOCall *call = self.callMap[uuid];
    if (call) {
        TVOCallMessage *callMessage = [TVOCallMessage messageWithContent:content
                                                             messageType:messageType
                                                                   block:^(TVOCallMessageBuilder *builder) {
            builder.contentType = contentType;
        }];
        NSString *voiceEventSid = [call sendMessage:callMessage];
        [self resolvePromise:resolver value:voiceEventSid];
    } else if (callInvite) {
        TVOCallMessage *callMessage = [TVOCallMessage messageWithContent:content
                                                             messageType:messageType
                                                                   block:^(TVOCallMessageBuilder *builder) {
            builder.contentType = contentType;
        }];
        NSString *voiceEventSid = [callInvite sendMessage:callMessage];
        [self resolvePromise:resolver value:voiceEventSid];
    } else {
        NSString *errorMessage = [NSString stringWithFormat:@"Call with %@ not found", uuid];
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
    }
}

#pragma mark - Bindings (Call Invite)

- (TVOCallInvite *)getCallInviteFromMap:(NSString *)uuid resolver:(RCTPromiseResolveBlock)resolver {
    TVOCallInvite *callInvite = self.callInviteMap[uuid];
    
    if (!callInvite) {
        [self rejectPromiseWithName:resolver
            name:kTwilioVoiceReactNativeErrorCodeInvalidStateError
            message:@"No matching call invite"
        ];
        return nil;
    }
    
    return callInvite;
}

RCT_EXPORT_METHOD(callInvite_accept:(NSString *)uuid
                  acceptOptions:(NSDictionary *)acceptOptions
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self answerCallInvite:[[NSUUID alloc] initWithUUIDString:uuid]
                completion:^(BOOL success, NSError *error) {
        if (!success) {
            [self rejectPromiseWithCode:resolver code:@(error.code) message:error.localizedDescription];
            return;
        }
        
        for (NSString *uuidKey in [self.callMap allKeys]) {
            if ([uuidKey isEqualToString:uuid]) {
                TVOCall *call = self.callMap[uuidKey];
                [self resolvePromise:resolver value:[self callInfo:call]];
                return;
            }
        }
        
        NSString *errorMessage = @"No matching call";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
    }];
}

RCT_EXPORT_METHOD(callInvite_reject:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self endCallWithUuid:[[NSUUID alloc] initWithUUIDString:uuid]];
    [self resolvePromise:resolver value:[NSNull null]];
}

RCT_EXPORT_METHOD(callInvite_isValid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    [self resolvePromise:resolver value:@(YES)];
}

RCT_EXPORT_METHOD(callInvite_getCallSid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self resolvePromise:resolver value:callInvite.callSid];
}

RCT_EXPORT_METHOD(callInvite_getFrom:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self resolvePromise:resolver value:callInvite.from];
}

RCT_EXPORT_METHOD(callInvite_getTo:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self resolvePromise:resolver value:callInvite.to];
}

RCT_EXPORT_METHOD(callInvite_updateCallerHandle:(NSString *)uuid
                  handle:(NSString *)handle
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCallInvite *callInvite = [self getCallInviteFromMap:uuid resolver:resolver];
    if (!callInvite) return;
    
    [self updateCall:uuid callerHandle:handle];
    [self resolvePromise:resolver value:[NSNull null]];
}

- (TVOCancelledCallInvite *)getCancelledCallInviteFromMap:(NSString *)uuid resolver:(RCTPromiseResolveBlock)resolver {
    TVOCancelledCallInvite *cancelledCallInvite = self.cancelledCallInviteMap[uuid];
    if (!cancelledCallInvite) {
        NSString *errorMessage = @"No matching cancelled call invite";
        [self rejectPromiseWithName:resolver name:kTwilioVoiceReactNativeErrorCodeInvalidStateError message:errorMessage];
        return nil;
    }
    
    return cancelledCallInvite;
}

RCT_EXPORT_METHOD(cancelledCallInvite_getCallSid:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCancelledCallInvite *cancelledCallInvite = [self getCancelledCallInviteFromMap:uuid resolver:resolver];
    if (!cancelledCallInvite) return;
    
    [self resolvePromise:resolver value:cancelledCallInvite.callSid];
}

RCT_EXPORT_METHOD(cancelledCallInvite_getFrom:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCancelledCallInvite *cancelledCallInvite = [self getCancelledCallInviteFromMap:uuid resolver:resolver];
    if (!cancelledCallInvite) return;
    
    [self resolvePromise:resolver value:cancelledCallInvite.from];
}

RCT_EXPORT_METHOD(cancelledCallInvite_getTo:(NSString *)uuid
                  resolver:(RCTPromiseResolveBlock)resolver
                  rejecter:(RCTPromiseRejectBlock)rejecter)
{
    TVOCancelledCallInvite *cancelledCallInvite = [self getCancelledCallInviteFromMap:uuid resolver:resolver];
    if (!cancelledCallInvite) return;
    
    [self resolvePromise:resolver value:cancelledCallInvite.to];
}

#pragma mark - utility

- (NSString *)stringOfState:(TVOCallState)state {
    switch (state) {
        case TVOCallStateConnecting:
            return kTwilioVoiceReactNativeCallStateConnecting;
        case TVOCallStateRinging:
            return kTwilioVoiceReactNativeCallStateRinging;
        case TVOCallStateConnected:
            return kTwilioVoiceReactNativeCallStateConnected;
        case TVOCallStateReconnecting:
            return kTwilioVoiceReactNativeCallStateReconnecting;
        case TVOCallStateDisconnected:
            return kTwilioVoiceReactNativeCallStateDisconnected;
        default:
            return kTwilioVoiceReactNativeCallStateConnecting;
    }
}

- (TVOCallFeedbackScore)scoreFromString:(NSString *)score {
    if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreNotReported]) {
        return TVOCallFeedbackScoreNotReported;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreOne]) {
        return TVOCallFeedbackScoreOnePoint;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreTwo]) {
        return TVOCallFeedbackScoreTwoPoints;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreThree]) {
        return TVOCallFeedbackScoreThreePoints;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreFour]) {
        return TVOCallFeedbackScoreFourPoints;
    } else if ([score isEqualToString:kTwilioVoiceReactNativeCallFeedbackScoreFive]) {
        return TVOCallFeedbackScoreFivePoints;
    }
    return TVOCallFeedbackScoreNotReported;
}

- (TVOCallFeedbackIssue)issueFromString:(NSString *)issue {
    if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueNotReported]) {
        return TVOCallFeedbackIssueNotReported;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueDroppedCall]) {
        return TVOCallFeedbackIssueDroppedCall;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueAudioLatency]) {
        return TVOCallFeedbackIssueAudioLatency;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueOneWayAudio]) {
        return TVOCallFeedbackIssueOneWayAudio;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueChoppyAudio]) {
        return TVOCallFeedbackIssueChoppyAudio;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueNoisyCall]) {
        return TVOCallFeedbackIssueNoisyCall;
    } else if ([issue isEqualToString:kTwilioVoiceReactNativeCallFeedbackIssueEcho]) {
        return TVOCallFeedbackIssueEcho;
    }
    return TVOCallFeedbackIssueNotReported;
}

- (NSString *)warningNameWithNumber:(NSNumber *)warning {
    if ([warning intValue] < 0) {
        NSLog(@"Warning number out of TVOCallQualityWarning range");
        return [NSString stringWithFormat:@"unknown-quality-warning:%@", warning];
    }
    
    TVOCallQualityWarning warningValue = [warning intValue];
    switch (warningValue) {
        case TVOCallQualityWarningHighRtt:
            return @"high-rtt";
        case TVOCallQualityWarningHighJitter:
            return @"high-jitter";
        case TVOCallQualityWarningHighPacketsLostFraction:
            return @"high-packet-loss";
        case TVOCallQualityWarningLowMos:
            return @"low-mos";
        case TVOCallQualityWarningConstantAudioInputLevel:
            return @"constant-audio-input-level";
        case TVOCallQualityWarningConstantAudioOutputLevel:
            return @"constant-audio-output-level";
        default:
            return [NSString stringWithFormat:@"unknown-quality-warning:%@", warning];
    }
}

- (NSMutableArray *)callQualityWarningsArrayFromSet:(NSSet<NSNumber *> *)qualityWarnings {
  NSMutableArray<NSString *> *warningEvents = [NSMutableArray array];
  for (NSNumber *warning in qualityWarnings) {
      NSString *event = [self warningNameWithNumber:warning];
      [warningEvents addObject:event];
  }
  return warningEvents;
}

@end
