package com.twiliovoicereactnative;

import android.content.Context;
import android.os.PowerManager;

/**
 * Turns the screen off when the phone is held to the ear during a call, like the system dialer.
 *
 * Without it the screen stayed on against the user's cheek during calls on Android, which also
 * caused accidental taps (mute, hang up, keypad). The proximity wake lock is held only while a
 * call is connected and audio is routed to the earpiece; it is released on speaker, Bluetooth or
 * wired headset and when the last call ends.
 */
final class ProximityManager {
  private static final SDKLog logger = new SDKLog(ProximityManager.class);
  private final PowerManager.WakeLock wakeLock;
  private boolean callActive = false;
  private boolean earpieceSelected = true;

  ProximityManager(Context context) {
    final PowerManager powerManager = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
    PowerManager.WakeLock lock = null;
    if (null != powerManager
      && powerManager.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
      lock = powerManager.newWakeLock(
        PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "twiliovoicereactnative:proximity");
      lock.setReferenceCounted(false);
    }
    wakeLock = lock;
  }

  synchronized void onCallActive(final boolean active) {
    callActive = active;
    update();
  }

  synchronized void onEarpieceSelected(final boolean selected) {
    earpieceSelected = selected;
    update();
  }

  private void update() {
    if (null == wakeLock) {
      return;
    }
    final boolean shouldHold = callActive && earpieceSelected;
    try {
      if (shouldHold && !wakeLock.isHeld()) {
        wakeLock.acquire();
      } else if (!shouldHold && wakeLock.isHeld()) {
        wakeLock.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY);
      }
    } catch (RuntimeException e) {
      logger.warning(e, "Proximity wake lock update failed");
    }
  }
}
