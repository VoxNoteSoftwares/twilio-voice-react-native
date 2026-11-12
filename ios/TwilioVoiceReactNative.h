//
//  TwilioVoiceReactNative.h
//  TwilioVoiceReactNative
//
//  Copyright © 2022 Twilio, Inc. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@class CXCallController;
@class CXProvider;
@class CXProviderConfiguration;
@class TVOCall;
@class TVOCallInvite;
@class TVOCancelledCallInvite;
@class TVODefaultAudioDevice;
@class TVOPreflightTest;

FOUNDATION_EXPORT NSString * const kTwilioVoiceReactNativeEventKeyCall;
FOUNDATION_EXPORT NSString * const kTwilioVoiceReactNativeEventKeyCallInvite;
FOUNDATION_EXPORT NSString * const kTwilioVoiceReactNativeEventKeyCancelledCallInvite;
FOUNDATION_EXPORT void VoxNoteRegisterDefaultCallingProvider(CXProvider *provider);
FOUNDATION_EXPORT CXProvider * _Nullable VoxNoteDefaultCallingProvider(void);

@interface TwilioVoiceReactNative : RCTEventEmitter <RCTBridgeModule>

@property (nonatomic, readonly, strong) NSMutableDictionary<NSString *, TVOCall *> *callMap;
@property (nonatomic, readonly, strong) NSMutableDictionary<NSString *, NSString *> *callConnectMap;
@property (nonatomic, readonly, strong) NSMutableDictionary<NSString *, TVOCallInvite *> *callInviteMap;
@property (nonatomic, readonly, strong) NSMutableDictionary<NSString *, TVOCancelledCallInvite *> *cancelledCallInviteMap;
@property (nonatomic, readonly, strong) NSMutableDictionary<NSString *, NSString *> *callIceGenerationMap;

@property (nonatomic, strong) CXProvider *callKitProvider;
@property (nonatomic, strong) CXCallController *callKitCallController;
@property (nonatomic, strong) CXProviderConfiguration *callKitConfiguration;

@property (nonatomic, copy) NSString *accessToken;
@property (nonatomic, copy) NSDictionary *twimlParams;
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *iceServers;
@property (nonatomic, copy, nullable) NSString *iceTransportPolicy;
@property (nonatomic, copy, nullable) NSString *iceGenerationId;
@property (nonatomic, strong, nullable) NSNumber *iceExpiresAt;
@property (nonatomic, copy) NSString *iceApplicationStatus;
@property (nonatomic, strong, nullable) NSNumber *iceAttemptedAt;
@property (nonatomic, strong, nullable) NSNumber *iceAppliedAt;
@property (nonatomic, copy, nullable) NSString *iceApplicationErrorCode;
@property (nonatomic, strong) void(^callKitCompletionCallback)(BOOL, NSError *error);
@property (nonatomic, strong) RCTPromiseResolveBlock callPromiseResolver;

@property (nonatomic, strong) TVOPreflightTest *preflightTest;
@property (nonatomic, copy) NSString *preflightTestUuid;
@property (nonatomic, strong) NSMutableArray *preflightTestEvents;

// Indicates if the disconnect is triggered from app UI, instead of the system Call UI
@property (nonatomic, assign) BOOL userInitiatedDisconnect;

@property (nonatomic, strong) AVAudioPlayer *ringbackPlayer;

+ (TVODefaultAudioDevice *)twilioAudioDevice;

- (void)voxnoteSetCallAudioOwned:(BOOL)owned;
- (void)voxnoteRefreshCallAudioOwnership;

- (NSString *)warningNameWithNumber:(NSNumber *)warning;
- (NSMutableArray *)callQualityWarningsArrayFromSet:(NSSet<NSNumber *> *)qualityWarnings;

@end

@interface TwilioVoiceReactNative (EventEmitter)

// Override so we can check the event observer before emitting events
- (void)sendEventWithName:(NSString *)eventName body:(id)body;

@end

@interface TwilioVoiceReactNative (CallKit)

- (void)initializeCallKit;
- (void)initializeCallKitWithConfiguration:(NSDictionary *)configuration;
- (void)makeCallWithAccessToken:(NSString *)accessToken
                         params:(NSDictionary *)params
                  contactHandle:(NSString *)contactHandle
                     iceServers:(NSArray<NSDictionary *> * _Nullable)iceServers
             iceTransportPolicy:(NSString * _Nullable)iceTransportPolicy;
- (void)reportNewIncomingCall:(TVOCallInvite *)callInvite;
- (void)endCallWithUuid:(NSUUID *)uuid;
/* Initiate the answering from the app UI */
- (void)answerCallInvite:(NSUUID *)uuid
              completion:(void(^)(BOOL success, NSError *error))completionHandler;
- (void)updateCall:(NSString *)uuid callerHandle:(NSString *)handle;

/* Utility */
- (NSDictionary *)callInfo:(TVOCall *)call;
- (NSDictionary *)callInviteInfo:(TVOCallInvite *)callInvite;
- (NSDictionary *)cancelledCallInviteInfo:(TVOCancelledCallInvite *)cancelledCallInvite;

@end

@interface TwilioVoiceReactNative (PromiseAdapter)

- (void)resolvePromise:(RCTPromiseResolveBlock)resolver value:(id)value;
- (void)rejectPromiseWithCode:(RCTPromiseResolveBlock)resolver code:(NSNumber *)code message:(NSString *)message;
- (void)rejectPromiseWithName:(RCTPromiseResolveBlock)resolver name:(NSString *)name message:(NSString *)message;

@end
