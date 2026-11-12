package com.twiliovoicereactnative;

import static com.twiliovoicereactnative.VoiceApplicationProxy.getCallRecordDatabase;
import static com.twiliovoicereactnative.VoiceApplicationProxy.getVoiceServiceApi;

import com.twiliovoicereactnative.CallRecordDatabase.CallRecord;

import android.os.PowerManager;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;
import com.twilio.voice.CallException;
import com.twilio.voice.CallInvite;
import com.twilio.voice.CancelledCallInvite;
import com.twilio.voice.MessageListener;
import com.twilio.voice.Voice;

import java.util.Objects;
import java.util.UUID;

public class VoiceFirebaseMessagingService extends FirebaseMessagingService {
  private static final SDKLog logger = new SDKLog(VoiceFirebaseMessagingService.class);

  public static class MessageHandler implements MessageListener  {
    @Override
    public void onCallInvite(@NonNull CallInvite callInvite) {
      logger.log(String.format("onCallInvite %s", callInvite.getCallSid()));

      final CallRecord callRecord = new CallRecord(UUID.randomUUID(), callInvite);

      getCallRecordDatabase().add(callRecord);
      getVoiceServiceApi().incomingCall(callRecord);
    }

    @Override
    public void onCancelledCallInvite(@NonNull CancelledCallInvite cancelledCallInvite,
                                      @Nullable CallException callException) {
      logger.log(String.format("onCancelledCallInvite %s", cancelledCallInvite.getCallSid()));

      // A cancel can arrive for an invite that was already answered, rejected or never seen
      // (late/duplicate pushes); that must not crash the messaging service.
      final CallRecord callRecord =
        getCallRecordDatabase().remove(new CallRecord(cancelledCallInvite.getCallSid()));
      if (null == callRecord) {
        logger.warning(String.format("onCancelledCallInvite %s: no matching invite, ignoring",
          cancelledCallInvite.getCallSid()));
        return;
      }

      callRecord.setCancelledCallInvite(cancelledCallInvite);
      callRecord.setCallException(callException);
      getVoiceServiceApi().cancelCall(callRecord);
    }
  }

  @Override
  public void onNewToken(@NonNull String token) {
    logger.log("Refreshed FCM token: " + token);
    FirebaseMessagingDelegates.forwardNewToken(this, token);
  }

  /**
   * Called when message is received.
   *
   * @param remoteMessage Object representing the message received from Firebase Cloud Messaging.
   */
  @Override
  public void onMessageReceived(RemoteMessage remoteMessage) {
    logger.debug("onMessageReceived remoteMessage: " + remoteMessage.toString());
    logger.debug("Bundle data: " + remoteMessage.getData());
    logger.debug("From: " + remoteMessage.getFrom());

    // Only wake the screen for an incoming call invite, not for every push the app receives.
    if ("twilio.voice.call".equals(remoteMessage.getData().get("twi_message_type"))) {
      PowerManager pm = (PowerManager)getSystemService(POWER_SERVICE);
      if (!pm.isInteractive()) {
        PowerManager.WakeLock wl = pm.newWakeLock(
          PowerManager.SCREEN_DIM_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP,
          "VoiceFirebaseMessagingService:notificationLock");
        wl.acquire(30000);
      }
    }

    // Check if message contains a data payload.
    if (!remoteMessage.getData().isEmpty()) {
      if (!Voice.handleMessage(
        this,
        remoteMessage.getData(),
        new MessageHandler(),
        new CallMessageListenerProxy())) {
        logger.debug("Not a Twilio Voice payload, forwarding to the app's other messaging services");
        FirebaseMessagingDelegates.forwardMessage(this, remoteMessage);
      }
    } else {
      FirebaseMessagingDelegates.forwardMessage(this, remoteMessage);
    }
  }
}
