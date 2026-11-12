package com.twiliovoicereactnative;

import android.content.Context;

/** Process-wide bridge used by Twilio, Expo Audio, and Expo Video. */
final class CallAudioOwnershipRegistry {
  static final String PREFERENCES = "voxnote_call_audio_ownership";
  static final String OWNED_KEY = "voxnote_call_audio_owned";

  private CallAudioOwnershipRegistry() {}

  static void setOwned(Context context, boolean owned) {
    context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .edit()
      .putBoolean(OWNED_KEY, owned)
      .apply();
  }

  static void reconcile(Context context) {
    setOwned(context, !VoiceApplicationProxy.getCallRecordDatabase().getCollection().isEmpty());
  }
}
