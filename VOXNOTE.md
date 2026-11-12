# VoxNote fork of @twilio/voice-react-native-sdk

Base: upstream tag **1.8.1** (October 12, 2026). This is the maintained line, and it supports Expo through the config plugin. Upstream no longer maintains `2.0.0-preview.x`. The 2.0.0-preview.2 tag is an ancestor of 1.8.1.

Branch: `voxnote/android-fixes`. Tags: `1.8.1-voxnote.N`.

Install it in the app from a tag:

```json
"@twilio/voice-react-native-sdk": "github:VoxNoteSoftwares/twilio-voice-react-native#1.8.1-voxnote.1"
```

## What changes compared with upstream 1.8.1

| Commit subject | Upstream issue | What it fixes |
| --- | --- | --- |
| port VoxNote patch-package changes onto 1.8.1 | — | Replaces `patches/@twilio+voice-react-native-sdk+2.0.0-preview.2.patch`: ICE configuration store, call-audio ownership, CallKit lifecycle and diagnostics, display name. On Android, the native methods move from the Expo module that 1.8 removed into the bridge module. |
| don't crash when a Call.Listener event has no call record | [#581](https://github.com/twilio/twilio-voice-react-native/issues/581) | NPE in `CallListenerProxy` callbacks |
| opt out of launch-time permission prompt; scope lock-screen flags to calls | [#670](https://github.com/twilio/twilio-voice-react-native/issues/670), [#586](https://github.com/twilio/twilio-voice-react-native/issues/586) | Crash when the permission prompt opens at startup. Screen never locking. |
| fall back to the bound VoiceService when startService is refused | [#587](https://github.com/twilio/twilio-voice-react-native/issues/587) | `BackgroundServiceStartNotAllowedException` (Samsung, Android 15) |
| ship consumer ProGuard/R8 rules | [#643](https://github.com/twilio/twilio-voice-react-native/issues/643), [#604](https://github.com/twilio/twilio-voice-react-native/issues/604) | Crashes in minified builds only |
| track call sounds per call; respect ringer mode and DND | [#708](https://github.com/twilio/twilio-voice-react-native/issues/708), [#710](https://github.com/twilio/twilio-voice-react-native/issues/710), [#559](https://github.com/twilio/twilio-voice-react-native/issues/559) | Ringtone stuck looping, ringtone silenced on another call, ringer mode and DND ignored |
| stop AudioSwitch from latching onto a Bluetooth SCO link it did not open | [#711](https://github.com/twilio/twilio-voice-react-native/issues/711) | Bluetooth headset flapping, mic held with no call |
| report the outcome of notification answers made before JS starts | [#744](https://github.com/twilio/twilio-voice-react-native/issues/744) | New API: `Voice.consumeNotificationAnswerOutcome()` |
| use a phoneCall foreground service | [#583](https://github.com/twilio/twilio-voice-react-native/issues/583) | Dead mic on calls answered from the lock screen or the background (Android 14+) |
| turn the screen off near the ear during earpiece calls | — (VOXNOTE-397) | Proximity sensor during calls |
| only hand the first disconnect() to the Twilio SDK | [#618](https://github.com/twilio/twilio-voice-react-native/issues/618) | UI freeze and `SSL_shutdown` errors on repeated disconnects |
| coexist with other FCM services; null-safe cancelled invites | [#370](https://github.com/twilio/twilio-voice-react-native/issues/370) | Incoming calls lost when `@react-native-firebase/messaging` or `expo-notifications` is installed (other pushes are forwarded). NPE on a late cancel. Screen woken for every push. |
| emit Voice.Event.TokenWillExpire | [#597](https://github.com/twilio/twilio-voice-react-native/issues/597) | New event about 1 minute before the token's `exp` |

Already fixed upstream in 1.8.1, so no commit here: [#709](https://github.com/twilio/twilio-voice-react-native/issues/709) (PendingIntents shared between calls) and the NPE in `VoiceService.onStartCommand` ([#643](https://github.com/twilio/twilio-voice-react-native/issues/643), [#604](https://github.com/twilio/twilio-voice-react-native/issues/604)).

Older Android issues that these commits also cover: #420 (screen visible over the lock screen → #586), #384 (crash in a release build only → ProGuard rules), #343 (permissions → `requestPermissionsOnLaunch`).

Not addressed: upstream's iOS issues (#722, #715, #706, #704, #694, #668, #665, #612, #610, #696). The VoxNote iOS patch already covers part of CallKit.

## New Expo config plugin option

```json
["@twilio/voice-react-native-sdk", { "android": { "requestPermissionsOnLaunch": false } }]
```

With this option, the SDK does not request permissions when the activity is created. The app requests them from its own onboarding.

## Checks

The cloud build environment cannot reach Maven or Google, so there was no Gradle build. The native code was only checked for syntax with `javac` and `tsc` (syntax errors only). You must run an Android build (EAS or local Gradle) and an iOS build before releasing.

To realign with a new upstream version, rebase `voxnote/android-fixes` onto the new tag. Each commit is self-contained.
