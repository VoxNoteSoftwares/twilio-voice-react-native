package com.twiliovoicereactnative;

import android.content.Context;
import android.content.SharedPreferences;

import androidx.annotation.Nullable;
import androidx.security.crypto.EncryptedSharedPreferences;
import androidx.security.crypto.MasterKey;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.WritableMap;
import com.twilio.voice.IceOptions;
import com.twilio.voice.IceServer;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

final class IceConfigurationStore {
  private static final String PREFERENCES_NAME = "voxnote_twilio_ice_configuration";
  private static final String CONFIGURATION_KEY = "configuration";

  private static String generationId;
  private static long expiresAt;
  private static IceOptions iceOptions;
  private static int serverCount;
  private static String status = "none";
  private static long attemptedAt;
  private static long appliedAt;
  private static String errorCode;

  private IceConfigurationStore() {}

  static synchronized void initialize(Context context) {
    if (iceOptions != null && expiresAt > System.currentTimeMillis()) return;
    try {
      String raw = preferences(context).getString(CONFIGURATION_KEY, null);
      if (raw == null) return;
      JSONObject configuration = new JSONObject(raw);
      JSONArray jsonServers = configuration.getJSONArray("iceServers");
      Set<IceServer> servers = new HashSet<>();
      for (int index = 0; index < jsonServers.length(); index++) {
        JSONObject server = jsonServers.getJSONObject(index);
        String serverUrl = server.getString(CommonConstants.IceServerKeyServerUrl);
        String username = server.optString(CommonConstants.IceServerKeyUsername, "");
        String password = server.optString(CommonConstants.IceServerKeyPassword, "");
        servers.add(username.isEmpty() && password.isEmpty()
          ? new IceServer(serverUrl)
          : new IceServer(serverUrl, username, password));
      }
      applyInMemory(
        configuration.getString("generationId"),
        servers,
        configuration.getLong("expiresAt")
      );
      if (iceOptions == null) clear(context);
    } catch (Exception error) {
      try {
        preferences(context).edit().remove(CONFIGURATION_KEY).commit();
      } catch (Exception ignored) {
        // The in-memory state is still rejected below.
      }
      generationId = null;
      expiresAt = 0;
      iceOptions = null;
      serverCount = 0;
      status = "failed";
      errorCode = error.getClass().getSimpleName();
    }
  }

  static synchronized void setConfiguration(
    Context context,
    String nextGenerationId,
    List<? extends Map<?, ?>> jsServers,
    long nextExpiresAt
  ) throws Exception {
    attemptedAt = System.currentTimeMillis();
    status = "pending";
    if (nextGenerationId == null || nextGenerationId.isEmpty() ||
        jsServers == null || jsServers.isEmpty() || nextExpiresAt <= attemptedAt) {
      status = "failed";
      errorCode = "invalid_configuration";
      throw new IllegalArgumentException("Invalid or expired ICE configuration");
    }

    Set<IceServer> servers = new HashSet<>();
    JSONArray persistedServers = new JSONArray();
    for (Map<?, ?> jsServer : jsServers) {
      Object rawUrl = jsServer.get(CommonConstants.IceServerKeyServerUrl);
      if (!(rawUrl instanceof String) || ((String) rawUrl).isEmpty()) {
        status = "failed";
        errorCode = "invalid_server";
        throw new IllegalArgumentException("ICE server URL must be a non-empty string");
      }
      String serverUrl = (String) rawUrl;
      String username = valueOrEmpty(jsServer.get(CommonConstants.IceServerKeyUsername));
      String password = valueOrEmpty(jsServer.get(CommonConstants.IceServerKeyPassword));
      servers.add(username.isEmpty() && password.isEmpty()
        ? new IceServer(serverUrl)
        : new IceServer(serverUrl, username, password));
      JSONObject persistedServer = new JSONObject();
      persistedServer.put(CommonConstants.IceServerKeyServerUrl, serverUrl);
      persistedServer.put(CommonConstants.IceServerKeyUsername, username);
      persistedServer.put(CommonConstants.IceServerKeyPassword, password);
      persistedServers.put(persistedServer);
    }

    JSONObject persisted = new JSONObject();
    persisted.put("generationId", nextGenerationId);
    persisted.put("iceServers", persistedServers);
    persisted.put("expiresAt", nextExpiresAt);
    if (!preferences(context).edit().putString(CONFIGURATION_KEY, persisted.toString()).commit()) {
      status = "failed";
      errorCode = "encrypted_preferences_write_failed";
      throw new IllegalStateException("Failed to persist ICE configuration");
    }
    applyInMemory(nextGenerationId, servers, nextExpiresAt);
    if (iceOptions == null) throw new IllegalArgumentException("Expired ICE configuration");
  }

  @Nullable
  static synchronized IceOptions getValidIceOptions(Context context) {
    initialize(context);
    if (expiresAt <= System.currentTimeMillis()) {
      try {
        clear(context);
      } catch (Exception error) {
        status = "failed";
        errorCode = error.getClass().getSimpleName();
      }
      return null;
    }
    return iceOptions;
  }

  static synchronized WritableMap getState(Context context) {
    IceOptions validOptions = getValidIceOptions(context);
    WritableMap state = Arguments.createMap();
    if (generationId != null) state.putString("generationId", generationId);
    else state.putNull("generationId");
    state.putInt("serverCount", validOptions == null ? 0 : serverCount);
    if (expiresAt > 0) state.putDouble("expiresAt", expiresAt);
    else state.putNull("expiresAt");
    state.putString("policy", "all");
    state.putBoolean("isValid", validOptions != null);
    state.putString("status", status);
    if (attemptedAt > 0) state.putDouble("attemptedAt", attemptedAt);
    else state.putNull("attemptedAt");
    if (appliedAt > 0) state.putDouble("appliedAt", appliedAt);
    else state.putNull("appliedAt");
    if (errorCode != null) state.putString("errorCode", errorCode);
    else state.putNull("errorCode");
    return state;
  }

  @Nullable
  static synchronized String getValidGenerationId(Context context) {
    return getValidIceOptions(context) == null ? null : generationId;
  }

  static synchronized void clear(Context context) throws Exception {
    Exception clearError = null;
    boolean cleared = false;
    try {
      cleared = preferences(context).edit().remove(CONFIGURATION_KEY).commit();
    } catch (Exception error) {
      clearError = error;
    }
    generationId = null;
    expiresAt = 0;
    iceOptions = null;
    serverCount = 0;
    status = "none";
    errorCode = null;
    if (clearError != null) throw clearError;
    if (!cleared) throw new IllegalStateException("Failed to clear persisted ICE configuration");
  }

  private static void applyInMemory(String nextGenerationId, Set<IceServer> servers, long nextExpiresAt) {
    if (servers.isEmpty() || nextExpiresAt <= System.currentTimeMillis()) {
      iceOptions = null;
      return;
    }
    iceOptions = new IceOptions.Builder().iceServers(servers).build();
    generationId = nextGenerationId;
    expiresAt = nextExpiresAt;
    serverCount = servers.size();
    appliedAt = System.currentTimeMillis();
    status = "applied";
    errorCode = null;
  }

  private static SharedPreferences preferences(Context context) throws Exception {
    MasterKey masterKey = new MasterKey.Builder(context)
      .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
      .build();
    return EncryptedSharedPreferences.create(
      context,
      PREFERENCES_NAME,
      masterKey,
      EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
      EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    );
  }

  private static String valueOrEmpty(Object value) {
    return value instanceof String ? (String) value : "";
  }
}
