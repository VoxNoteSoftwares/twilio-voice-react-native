package com.twiliovoicereactnative;

import android.app.NotificationManager;
import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.SoundPool;
import android.os.Build;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * Plays the SDK's call sounds.
 *
 * Streams are tracked per call (by call UUID) so overlapping calls cannot leak or silence each
 * other's sounds:
 * <ul>
 *   <li>#708: a single {@code activeStream} field was overwritten when a second invite started
 *   ringing, so the first looping ringtone could never be stopped.</li>
 *   <li>#710: stopping one call's sound stopped whatever stream happened to be "active",
 *   silencing another call that was still ringing.</li>
 * </ul>
 * The incoming-call ringtone also honours the ringer mode and Do Not Disturb (#559).
 */
class MediaPlayerManager {
  private static final SDKLog logger = new SDKLog(MediaPlayerManager.class);

  public enum SoundTable {
    INCOMING,
    OUTGOING,
    DISCONNECT,
    RINGTONE
  }

  /** Owner used by callers that do not identify a call (legacy API). */
  private static final UUID NO_CALL = new UUID(0L, 0L);

  private final Context context;
  private final SoundPool callSoundPool;
  private final SoundPool ringtoneSoundPool;
  private final Map<SoundTable, Integer> soundMap;
  private final Map<UUID, List<Integer>> activeStreams = new HashMap<>();

  MediaPlayerManager(Context context) {
    this.context = context.getApplicationContext();
    callSoundPool = (new SoundPool.Builder())
      .setMaxStreams(4)
      .setAudioAttributes(
        new AudioAttributes.Builder()
          .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
          .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
          .build())
      .build();
    // The incoming ringtone plays on the ring stream so it follows the ring volume.
    ringtoneSoundPool = (new SoundPool.Builder())
      .setMaxStreams(4)
      .setAudioAttributes(
        new AudioAttributes.Builder()
          .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
          .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
          .build())
      .build();
    soundMap = new HashMap<>();
    soundMap.put(SoundTable.INCOMING, ringtoneSoundPool.load(context, R.raw.incoming, 1));
    soundMap.put(SoundTable.OUTGOING, callSoundPool.load(context, R.raw.outgoing, 1));
    soundMap.put(SoundTable.DISCONNECT, callSoundPool.load(context, R.raw.disconnect, 1));
    soundMap.put(SoundTable.RINGTONE, callSoundPool.load(context, R.raw.ringtone, 1));
  }

  /** Legacy API: play a sound not tied to a specific call. */
  public void play(final SoundTable sound) {
    play(NO_CALL, sound);
  }

  public synchronized void play(@Nullable final UUID callUuid, @NonNull final SoundTable sound) {
    if (SoundTable.INCOMING == sound && !shouldRing()) {
      logger.debug("Ringer is silent or Do Not Disturb is on; not playing the incoming ringtone");
      return;
    }
    final UUID owner = (null != callUuid) ? callUuid : NO_CALL;
    final SoundPool pool = poolFor(sound);
    final Integer soundId = soundMap.get(sound);
    if (null == soundId) {
      return;
    }
    final int streamId = pool.play(
      soundId,
      1.f,
      1.f,
      1,
      (SoundTable.DISCONNECT == sound) ? 0 : -1,
      1.f);
    if (0 == streamId) {
      return;
    }
    if (SoundTable.DISCONNECT != sound) {
      List<Integer> streams = activeStreams.get(owner);
      if (null == streams) {
        streams = new ArrayList<>();
        activeStreams.put(owner, streams);
      }
      // encode the pool in the sign so stop() knows which pool owns the stream
      streams.add(pool == ringtoneSoundPool ? -streamId : streamId);
    }
  }

  /** Stop the looping sounds owned by one call, leaving other calls' sounds untouched. */
  public synchronized void stop(@Nullable final UUID callUuid) {
    final List<Integer> streams = activeStreams.remove((null != callUuid) ? callUuid : NO_CALL);
    stopStreams(streams);
  }

  /** Legacy API: stop every looping sound. */
  public synchronized void stop() {
    for (List<Integer> streams : activeStreams.values()) {
      stopStreams(streams);
    }
    activeStreams.clear();
  }

  private void stopStreams(@Nullable final List<Integer> streams) {
    if (null == streams) {
      return;
    }
    for (Integer encoded : streams) {
      if (encoded < 0) {
        ringtoneSoundPool.stop(-encoded);
      } else {
        callSoundPool.stop(encoded);
      }
    }
  }

  private SoundPool poolFor(@NonNull final SoundTable sound) {
    return (SoundTable.INCOMING == sound) ? ringtoneSoundPool : callSoundPool;
  }

  private boolean shouldRing() {
    final AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    if (null != audioManager && AudioManager.RINGER_MODE_NORMAL != audioManager.getRingerMode()) {
      return false;
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      final NotificationManager notificationManager =
        (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
      if (null != notificationManager) {
        final int filter = notificationManager.getCurrentInterruptionFilter();
        if (NotificationManager.INTERRUPTION_FILTER_PRIORITY == filter) {
          // Priority-only DND: ring only if calls from anyone are let through (we cannot tell
          // whether a VoIP caller is a starred contact).
          try {
            final NotificationManager.Policy policy = notificationManager.getNotificationPolicy();
            return null != policy
              && 0 != (policy.priorityCategories & NotificationManager.Policy.PRIORITY_CATEGORY_CALLS)
              && NotificationManager.Policy.PRIORITY_SENDERS_ANY == policy.priorityCallSenders;
          } catch (SecurityException e) {
            return false;
          }
        }
        if (NotificationManager.INTERRUPTION_FILTER_ALL != filter
          && NotificationManager.INTERRUPTION_FILTER_UNKNOWN != filter) {
          return false;
        }
      }
    }
    return true;
  }

  @Override
  protected void finalize() throws Throwable {
    callSoundPool.release();
    ringtoneSoundPool.release();
    super.finalize();
  }
}
