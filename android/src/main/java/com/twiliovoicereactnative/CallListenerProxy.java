package com.twiliovoicereactnative;

import android.content.Context;
import android.util.Pair;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.facebook.react.bridge.WritableMap;
import com.twilio.voice.Call;
import com.twilio.voice.CallException;

import static com.twiliovoicereactnative.CommonConstants.CallEventConnected;
import static com.twiliovoicereactnative.CommonConstants.CallEventDisconnected;
import static com.twiliovoicereactnative.CommonConstants.CallEventReconnected;
import static com.twiliovoicereactnative.CommonConstants.CallEventReconnecting;
import static com.twiliovoicereactnative.CommonConstants.CallEventRinging;
import static com.twiliovoicereactnative.CommonConstants.ScopeCall;
import static com.twiliovoicereactnative.CommonConstants.VoiceEventType;
import static com.twiliovoicereactnative.CommonConstants.VoiceErrorKeyError;
import static com.twiliovoicereactnative.CommonConstants.CallEventCurrentWarnings;
import static com.twiliovoicereactnative.CommonConstants.CallEventPreviousWarnings;
import static com.twiliovoicereactnative.CommonConstants.CallEventConnectFailure;
import static com.twiliovoicereactnative.CommonConstants.CallEventQualityWarningsChanged;
import static com.twiliovoicereactnative.Constants.JS_EVENT_KEY_CALL_INFO;
import static com.twiliovoicereactnative.VoiceApplicationProxy.getCallRecordDatabase;
import static com.twiliovoicereactnative.VoiceApplicationProxy.getJSEventEmitter;
import static com.twiliovoicereactnative.VoiceApplicationProxy.getAudioSwitchManager;
import static com.twiliovoicereactnative.VoiceApplicationProxy.getMediaPlayerManager;
import static com.twiliovoicereactnative.VoiceApplicationProxy.getVoiceServiceApi;
import static com.twiliovoicereactnative.JSEventEmitter.constructJSMap;
import static com.twiliovoicereactnative.ReactNativeArgumentsSerializer.*;

import com.twiliovoicereactnative.CallRecordDatabase.CallRecord;

import java.util.Date;
import java.util.Set;
import java.util.UUID;

class CallListenerProxy implements Call.Listener {
  private static final SDKLog logger = new SDKLog(CallListenerProxy.class);
  private final UUID uuid;
  private final Context context;

  public CallListenerProxy(UUID uuid, Context context) {
    this.uuid = uuid;
    this.context = context;
  }

  @Override
  public void onConnectFailure(@NonNull Call call, @NonNull CallException callException) {
    debug("onConnectFailure");
    NotificationAnswerOutcome.update(uuid, NotificationAnswerOutcome.CONNECT_FAILURE, callException);

    // stop sound and routing
    getMediaPlayerManager().stop(uuid);
    getAudioSwitchManager().getAudioSwitch().deactivate();

    // find call record & remove
    CallRecord callRecord = getCallRecordDatabase().remove(new CallRecord(uuid));
    if (null == callRecord) {
      missingCallRecord("onConnectFailure");
      return;
    }

    // take down notification
    getVoiceServiceApi().cancelActiveCallNotification(callRecord);

    // serialize and notify JS
    sendJSEvent(
      constructJSMap(
        new Pair<>(VoiceEventType, CallEventConnectFailure),
        new Pair<>(JS_EVENT_KEY_CALL_INFO, serializeCall(callRecord)),
        new Pair<>(VoiceErrorKeyError, serializeVoiceException(callException))));
  }

  @Override
  public void onRinging(@NonNull Call call) {
    debug("onRinging");

    // find call record
    CallRecord callRecord = getCallRecordDatabase().get(new CallRecord(uuid));
    if (null == callRecord) {
      missingCallRecord("onRinging");
      return;
    }
    callRecord.setCall(call);

    // create notification & sound
    callRecord.setNotificationId(NotificationUtility.createNotificationIdentifier());
    getAudioSwitchManager().getAudioSwitch().activate();
    getMediaPlayerManager().play(uuid, MediaPlayerManager.SoundTable.RINGTONE);
    getVoiceServiceApi().raiseOutgoingCallNotification(callRecord);

    // notify JS layer
    sendJSEvent(
      constructJSMap(
        new Pair<>(VoiceEventType, CallEventRinging),
        new Pair<>(JS_EVENT_KEY_CALL_INFO, serializeCall(callRecord))));
  }

  @Override
  public void onConnected(@NonNull Call call) {
    debug("onConnected");
    NotificationAnswerOutcome.update(uuid, NotificationAnswerOutcome.CONNECTED, null);

    // find call record
    CallRecord callRecord = getCallRecordDatabase().get(new CallRecord(uuid));
    if (null == callRecord) {
      missingCallRecord("onConnected");
      return;
    }
    callRecord.setCall(call);
    callRecord.setTimestamp(new Date());
    getMediaPlayerManager().stop(uuid);

    // notify JS layer
    sendJSEvent(
      constructJSMap(
        new Pair<>(VoiceEventType, CallEventConnected),
        new Pair<>(JS_EVENT_KEY_CALL_INFO, serializeCall(callRecord))));
  }

  @Override
  public void onReconnecting(@NonNull Call call, @NonNull CallException callException) {
    debug("onReconnecting");

    // find & update call record
    CallRecord callRecord = getCallRecordDatabase().get(new CallRecord(uuid));
    if (null == callRecord) {
      missingCallRecord("onReconnecting");
      return;
    }

    // notify JS layer
    sendJSEvent(
      constructJSMap(
        new Pair<>(VoiceEventType, CallEventReconnecting),
        new Pair<>(JS_EVENT_KEY_CALL_INFO, serializeCall(callRecord)),
        new Pair<>(VoiceErrorKeyError, serializeVoiceException(callException))));
  }

  @Override
  public void onReconnected(@NonNull Call call) {
    debug("onReconnected");

    // find & update call record
    CallRecord callRecord = getCallRecordDatabase().get(new CallRecord(uuid));
    if (null == callRecord) {
      missingCallRecord("onReconnected");
      return;
    }

    // notify JS layer
    sendJSEvent(
      constructJSMap(
        new Pair<>(VoiceEventType, CallEventReconnected),
        new Pair<>(JS_EVENT_KEY_CALL_INFO, serializeCall(callRecord))));
  }

  @Override
  public void onDisconnected(@NonNull Call call, @Nullable CallException callException) {
    debug("onDisconnected");
    NotificationAnswerOutcome.update(uuid, NotificationAnswerOutcome.DISCONNECTED, callException);

    // stop audio first so a missing call record can never leave audio routing active
    getMediaPlayerManager().stop(uuid);
    getMediaPlayerManager().play(uuid, MediaPlayerManager.SoundTable.DISCONNECT);
    getAudioSwitchManager().getAudioSwitch().deactivate();

    // find & remove call record
    CallRecord callRecord = getCallRecordDatabase().remove(new CallRecord(uuid));
    if (null == callRecord) {
      missingCallRecord("onDisconnected");
      return;
    }

    // cancel notification
    getVoiceServiceApi().cancelActiveCallNotification(callRecord);

    // notify JS layer
    sendJSEvent(
      constructJSMap(
        new Pair<>(VoiceEventType, CallEventDisconnected),
        new Pair<>(JS_EVENT_KEY_CALL_INFO, serializeCall(callRecord)),
        new Pair<>(VoiceErrorKeyError, serializeVoiceException(callException))));
  }

  @Override
  public void onCallQualityWarningsChanged(@NonNull Call call,
                                           @NonNull Set<Call.CallQualityWarning> currentWarnings,
                                           @NonNull Set<Call.CallQualityWarning> previousWarnings) {
    debug("onCallQualityWarningsChanged");

    // find call record
    CallRecord callRecord = getCallRecordDatabase().get(new CallRecord(uuid));
    if (null == callRecord) {
      missingCallRecord("onCallQualityWarningsChanged");
      return;
    }

    // notify JS layer
    sendJSEvent(
      constructJSMap(
        new Pair<>(VoiceEventType, CallEventQualityWarningsChanged),
        new Pair<>(JS_EVENT_KEY_CALL_INFO, serializeCall(callRecord)),
        new Pair<>(CallEventCurrentWarnings, serializeCallQualityWarnings(currentWarnings)),
        new Pair<>(CallEventPreviousWarnings, serializeCallQualityWarnings(previousWarnings))));
  }

  /**
   * The call record can already be gone when a Call.Listener callback arrives (e.g. the call
   * was torn down from a notification action or by the OS while the SDK was still delivering
   * events). Throwing here crashed the app on the main looper; log and drop the event instead.
   * See twilio/twilio-voice-react-native#581.
   */
  private void missingCallRecord(final String callback) {
    logger.warning(String.format("%s: no call record for UUID:%s, ignoring", callback, uuid));
  }

  private void sendJSEvent(@NonNull WritableMap event) {
    getJSEventEmitter().sendEvent(ScopeCall, event);
  }

  private void debug(final String message) {
    logger.debug(String.format("%s UUID:%s", message, uuid.toString()));
  }
}
