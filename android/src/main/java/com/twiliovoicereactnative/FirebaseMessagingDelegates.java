package com.twiliovoicereactnative;

import android.app.Service;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;

import androidx.annotation.NonNull;

import com.google.firebase.messaging.FirebaseMessagingService;
import com.google.firebase.messaging.RemoteMessage;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

/**
 * Lets the SDK's messaging service coexist with the app's other FirebaseMessagingService
 * implementations (twilio-voice-react-native#370).
 *
 * Android delivers an FCM message to a single service. Apps that also use
 * {@code @react-native-firebase/messaging} or {@code expo-notifications} declare their own
 * services, and whichever one won lost the other's pushes: either incoming calls never rang, or
 * the app's own notifications and token refreshes were dropped. The SDK's service is declared with
 * a higher priority so call invites always reach it, and every message that is not a Twilio Voice
 * payload (plus every token refresh) is forwarded to the app's other messaging services.
 */
final class FirebaseMessagingDelegates {
  private static final SDKLog logger = new SDKLog(FirebaseMessagingDelegates.class);
  private static List<FirebaseMessagingService> delegates;

  private FirebaseMessagingDelegates() {}

  static void forwardMessage(@NonNull final Service host, @NonNull final RemoteMessage message) {
    for (FirebaseMessagingService delegate : getDelegates(host)) {
      try {
        delegate.onMessageReceived(message);
      } catch (Exception e) {
        logger.warning(e, "Forwarding FCM message to " + delegate.getClass().getName() + " failed");
      }
    }
  }

  static void forwardNewToken(@NonNull final Service host, @NonNull final String token) {
    for (FirebaseMessagingService delegate : getDelegates(host)) {
      try {
        delegate.onNewToken(token);
      } catch (Exception e) {
        logger.warning(e, "Forwarding FCM token to " + delegate.getClass().getName() + " failed");
      }
    }
  }

  private static synchronized List<FirebaseMessagingService> getDelegates(@NonNull final Service host) {
    if (null != delegates) {
      return delegates;
    }
    delegates = new ArrayList<>();
    final Intent intent = new Intent("com.google.firebase.MESSAGING_EVENT");
    intent.setPackage(host.getPackageName());
    final List<ResolveInfo> services = host.getPackageManager()
      .queryIntentServices(intent, PackageManager.GET_META_DATA);
    for (ResolveInfo info : services) {
      if (null == info.serviceInfo) continue;
      final String className = info.serviceInfo.name;
      if (VoiceFirebaseMessagingService.class.getName().equals(className)) continue;
      try {
        final Class<?> clazz = Class.forName(className);
        if (!FirebaseMessagingService.class.isAssignableFrom(clazz)) continue;
        final FirebaseMessagingService delegate =
          (FirebaseMessagingService) clazz.getDeclaredConstructor().newInstance();
        attachBaseContext(delegate, host.getApplicationContext());
        delegate.onCreate();
        delegates.add(delegate);
        logger.debug("FCM delegate registered: " + className);
      } catch (Throwable t) {
        logger.warning("Could not create FCM delegate " + className + ": " + t);
      }
    }
    return delegates;
  }

  private static void attachBaseContext(final Service service, final Context base) throws Exception {
    final Method method = ContextWrapper.class.getDeclaredMethod("attachBaseContext", Context.class);
    method.setAccessible(true);
    method.invoke(service, base);
  }
}
