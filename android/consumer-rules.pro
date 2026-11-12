# Twilio Voice Android SDK (https://www.twilio.com/docs/voice/sdks/android#set-up-proguard-rules)
-keep class com.twilio.** { *; }
-keep class tvo.webrtc.** { *; }
-dontwarn tvo.webrtc.**
-keep class com.twilio.voice.** { *; }
-keepattributes InnerClasses

# This React Native module (bridge methods, Firebase service, call records)
-keep class com.twiliovoicereactnative.** { *; }
