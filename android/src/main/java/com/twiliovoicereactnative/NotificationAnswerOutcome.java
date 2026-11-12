package com.twiliovoicereactnative;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.twilio.voice.CallException;

import java.util.Map;
import java.util.UUID;

/**
 * Single-slot record of the last call answered from the native notification
 * (twilio-voice-react-native#744).
 *
 * When the app is cold-started by tapping "Answer", VoiceService accepts the call before the
 * React Native runtime and its listeners exist, so the accepted / connectFailure events are
 * dropped, and a failed accept also removes the call record. A typical case is answering a call
 * whose caller already hung up while the cancel push was late or missing (some OEMs): the app
 * opened with no call UI and no error. JS can now ask what happened with
 * {@code Voice.consumeNotificationAnswerOutcome()} once it starts.
 */
final class NotificationAnswerOutcome {
  static final String PENDING = "pending";
  static final String CONNECTED = "connected";
  static final String CONNECT_FAILURE = "connectFailure";
  static final String DISCONNECTED = "disconnected";

  private static UUID uuid;
  private static String outcome;
  private static String callSid;
  private static String from;
  private static Map<String, String> customParameters;
  private static Integer errorCode;
  private static String errorMessage;
  private static long updatedAt;

  private NotificationAnswerOutcome() {}

  static synchronized void begin(@NonNull final CallRecordDatabase.CallRecord callRecord) {
    uuid = callRecord.getUuid();
    outcome = PENDING;
    callSid = callRecord.getCallSid();
    from = (null != callRecord.getCallInvite()) ? callRecord.getCallInvite().getFrom() : null;
    customParameters = callRecord.getCustomParameters();
    errorCode = null;
    errorMessage = null;
    updatedAt = System.currentTimeMillis();
  }

  static synchronized void update(@NonNull final UUID callUuid,
                                  @NonNull final String newOutcome,
                                  @Nullable final CallException error) {
    if (null == uuid || !uuid.equals(callUuid)) {
      return;
    }
    // a disconnect after a connect failure must not hide the failure
    if (DISCONNECTED.equals(newOutcome) && CONNECT_FAILURE.equals(outcome)) {
      return;
    }
    outcome = newOutcome;
    if (null != error) {
      errorCode = error.getErrorCode();
      errorMessage = error.getMessage();
    }
    updatedAt = System.currentTimeMillis();
  }

  /** Returns the last outcome once, then clears it. Null when there is none. */
  @Nullable
  static synchronized WritableMap consume() {
    if (null == uuid) {
      return null;
    }
    final WritableMap map = Arguments.createMap();
    map.putString("uuid", uuid.toString());
    map.putString("outcome", outcome);
    map.putString("callSid", callSid);
    map.putString("from", from);
    final WritableMap params = Arguments.createMap();
    if (null != customParameters) {
      for (Map.Entry<String, String> entry : customParameters.entrySet()) {
        params.putString(entry.getKey(), entry.getValue());
      }
    }
    map.putMap("customParameters", params);
    if (null != errorCode) {
      map.putInt("errorCode", errorCode);
    } else {
      map.putNull("errorCode");
    }
    map.putString("errorMessage", errorMessage);
    map.putDouble("updatedAt", (double) updatedAt);
    uuid = null;
    outcome = null;
    callSid = null;
    from = null;
    customParameters = null;
    errorCode = null;
    errorMessage = null;
    return map;
  }
}
