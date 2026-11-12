package com.twiliovoicereactnative;

import java.util.List;
import java.util.Vector;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.view.Window;
import android.view.WindowManager;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

public class VoiceActivityProxy {
  private static final SDKLog logger = new SDKLog(VoiceActivityProxy.class);
  private static final int PERMISSION_REQUEST_CODE = 101;
  private static final String[] permissionList;
  private final Activity context;
  private final PermissionsRationaleNotifier notifier;

  public interface PermissionsRationaleNotifier {
    void displayRationale(final String permission);
  }

  public VoiceActivityProxy(@NonNull Activity activity,
                            @NonNull PermissionsRationaleNotifier notifier) {
    this.context = activity;
    this.notifier = notifier;
  }
  public void onCreate(Bundle ignoredSavedInstanceState) {
    logger.debug("onCreate(): invoked");
    // Ensure the microphone permission is enabled. Requesting it here pauses the host activity
    // for GrantPermissionsActivity while React Native is still starting, which can crash in
    // ReactActivityDelegate.onUserLeaveHint (#670); applications can opt out with manifest
    // meta-data and request permissions themselves.
    if (shouldRequestPermissionsOnLaunch() && !checkPermissions()) {
      requestPermissions();
    }
    applyLockScreenFlags(context.getIntent());
    // handle any incoming intents
    handleIntent(context.getIntent());
  }
  public void onDestroy() {
    logger.debug("onDestroy(): invoked");
  }
  public void onNewIntent(Intent intent) {
    logger.debug("onNewIntent(...): invoked");
    applyLockScreenFlags(intent);
    handleIntent(intent);
  }
  /**
   * Only show over the lock screen / turn the screen on when the activity is brought up for a
   * call (full-screen incoming call or call notification), and never keep the screen on
   * permanently: FLAG_KEEP_SCREEN_ON on the host activity disabled screen lock for the whole
   * app (#586). Normal launches clear the flags again.
   */
  private void applyLockScreenFlags(Intent intent) {
    final String action = (null != intent) ? intent.getAction() : null;
    final boolean forCall = Constants.ACTION_PUSH_APP_TO_FOREGROUND.equals(action)
      || Constants.ACTION_ACCEPT_CALL.equals(action)
      || Constants.ACTION_FOREGROUND_AND_DEPRIORITIZE_INCOMING_CALL_NOTIFICATION.equals(action);
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
      context.setShowWhenLocked(forCall);
      context.setTurnScreenOn(forCall);
    } else {
      Window window = context.getWindow();
      final int flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
        | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON;
      if (forCall) {
        window.addFlags(flags);
      } else {
        window.clearFlags(flags);
      }
    }
  }
  private boolean shouldRequestPermissionsOnLaunch() {
    try {
      final android.content.pm.ApplicationInfo info = context.getPackageManager()
        .getApplicationInfo(context.getPackageName(), PackageManager.GET_META_DATA);
      return null == info.metaData
        || info.metaData.getBoolean(Constants.REQUEST_PERMISSIONS_ON_LAUNCH_METADATA, true);
    } catch (Exception e) {
      return true;
    }
  }
  private void requestPermissions() {
    List<String> permissionsRequestList = new Vector<>();
    for (final String permission: VoiceActivityProxy.permissionList) {
      permissionsRequestList.add(permission);
      if (ActivityCompat.shouldShowRequestPermissionRationale(context, permission)) {
        notifier.displayRationale(permission);
      }
    }
    ActivityCompat.requestPermissions(
      context,
      permissionsRequestList.toArray(new String[0]),
      PERMISSION_REQUEST_CODE);
  }
  private boolean checkPermissions() {
    for (String permission: VoiceActivityProxy.permissionList) {
      if (PackageManager.PERMISSION_GRANTED !=
        ContextCompat.checkSelfPermission(context, permission)) {
        return false;
      }
    }
    return true;
  }
  private void handleIntent(Intent intent) {
    String action = intent.getAction();
    if ((null != action) && (!action.equals(Constants.ACTION_PUSH_APP_TO_FOREGROUND))) {
      // Accept is an activity PendingIntent, so forwarding is its only path to VoiceService. The
      // copy constructor preserves extras (including the notification id); setFlags(0) resets flags only.
      Intent copiedIntent = new Intent(intent);
      copiedIntent.setClass(context.getApplicationContext(), VoiceService.class);
      copiedIntent.setFlags(0);
      try {
        context.getApplicationContext().startService(copiedIntent);
      } catch (IllegalStateException e) {
        // BackgroundServiceStartNotAllowedException (API 31+) extends IllegalStateException. It is
        // thrown when onNewIntent runs while the process is still considered in the background
        // (seen on Samsung Android 15, #587). The application keeps VoiceService bound, so hand the
        // intent to it directly.
        final VoiceService.VoiceServiceAPI api = VoiceApplicationProxy.getVoiceServiceApi();
        if (null != api) {
          logger.warning("startService refused in background, dispatching through bound service");
          api.dispatchIntent(copiedIntent);
        } else {
          logger.warning(e, "Cannot deliver notification action: service not bound");
        }
      }
    }
  }

  static {
    if (Build.VERSION.SDK_INT > Build.VERSION_CODES.S_V2) {
      permissionList = new String[] {
        Manifest.permission.RECORD_AUDIO,
        Manifest.permission.BLUETOOTH_CONNECT,
        Manifest.permission.POST_NOTIFICATIONS };
    } else if (Build.VERSION.SDK_INT > Build.VERSION_CODES.R) {
      permissionList = new String[] {
        Manifest.permission.RECORD_AUDIO, Manifest.permission.BLUETOOTH_CONNECT };
    } else {
      permissionList = new String[] { Manifest.permission.RECORD_AUDIO };
    }
  }
}
