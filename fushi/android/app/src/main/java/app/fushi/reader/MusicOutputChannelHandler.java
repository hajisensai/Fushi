package app.fushi.reader;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioDeviceInfo;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioMixerAttributes;
import android.os.Build;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * 音乐输出（USB DAC bit-perfect）的 Android 侧实现。
 *
 * <p>Dart 侧契约：{@code lib/src/media/music/music_platform_output.dart}，方法名 / 参数名 /
 * state 取值是跨语言契约，改这里必须同步改那边。
 *
 * <p>bit-perfect 混音属性是 Android 14（API 34）的可选 HAL 能力：不支持就如实回报
 * 设备提供的格式清单，不假装成功。
 */
public final class MusicOutputChannelHandler {
    static final String CHANNEL = "app.fushi.reader/music_output";
    private static final String METHOD_REQUEST = "requestBitPerfect";
    private static final String METHOD_CLEAR = "clearBitPerfect";

    private final Context context;
    @Nullable private MethodChannel channel;

    // 成功设置后记住，clear 时用。仅在 API 34+ 才会被赋值。
    @Nullable private AudioAttributes appliedAttributes;
    @Nullable private AudioDeviceInfo appliedDevice;

    public MusicOutputChannelHandler(@NonNull Context context) {
        this.context = context.getApplicationContext();
    }

    public void register(@NonNull FlutterEngine engine) {
        final MethodChannel created =
                new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL);
        created.setMethodCallHandler(this::onMethodCall);
        channel = created;
    }

    public void destroy() {
        if (channel != null) {
            channel.setMethodCallHandler(null);
            channel = null;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            clearInternal();
        }
    }

    private void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case METHOD_REQUEST:
                result.success(request(call));
                return;
            case METHOD_CLEAR:
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    clearInternal();
                }
                result.success(null);
                return;
            default:
                result.notImplemented();
        }
    }

    private static Map<String, Object> reply(String state, @Nullable String message) {
        Map<String, Object> m = new HashMap<>();
        m.put("state", state);
        if (message != null) {
            m.put("message", message);
        }
        return m;
    }

    private Map<String, Object> request(MethodCall call) {
        try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                return reply("unsupportedOs", null);
            }
            Integer sampleRate = call.argument("sampleRate");
            Integer channelCount = call.argument("channelCount");
            String encodingName = call.argument("encoding");
            if (sampleRate == null || channelCount == null || encodingName == null) {
                return reply("failed", "missing arguments");
            }
            return requestApi34(sampleRate, channelCount, encodingName);
        } catch (Throwable t) {
            return reply("failed", t.getClass().getSimpleName() + ": " + t.getMessage());
        }
    }

    private static int encodingOf(String name) {
        switch (name) {
            case "pcm16":
                return AudioFormat.ENCODING_PCM_16BIT;
            case "pcm24":
                return AudioFormat.ENCODING_PCM_24BIT_PACKED;
            case "pcm32":
                return AudioFormat.ENCODING_PCM_32BIT;
            case "float":
                return AudioFormat.ENCODING_PCM_FLOAT;
            default:
                return AudioFormat.ENCODING_INVALID;
        }
    }

    private static String encodingLabel(int encoding) {
        switch (encoding) {
            case AudioFormat.ENCODING_PCM_16BIT:
                return "pcm16";
            case AudioFormat.ENCODING_PCM_24BIT_PACKED:
                return "pcm24";
            case AudioFormat.ENCODING_PCM_32BIT:
                return "pcm32";
            case AudioFormat.ENCODING_PCM_FLOAT:
                return "float";
            default:
                return "enc" + encoding;
        }
    }

    @RequiresApi(34)
    private Map<String, Object> requestApi34(int sampleRate, int channelCount, String encodingName) {
        final AudioManager audioManager =
                (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        if (audioManager == null) {
            return reply("failed", "AudioManager unavailable");
        }
        AudioDeviceInfo usb = null;
        for (AudioDeviceInfo d : audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            int type = d.getType();
            if (type == AudioDeviceInfo.TYPE_USB_DEVICE || type == AudioDeviceInfo.TYPE_USB_HEADSET) {
                usb = d;
                break;
            }
        }
        if (usb == null) {
            return reply("noUsbDevice", null);
        }

        final int wantEncoding = encodingOf(encodingName);
        final List<AudioMixerAttributes> supported = audioManager.getSupportedMixerAttributes(usb);
        AudioMixerAttributes match = null;
        StringBuilder offered = new StringBuilder();
        for (AudioMixerAttributes a : supported) {
            if (a.getMixerBehavior() != AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT) {
                continue;
            }
            AudioFormat f = a.getFormat();
            int ch = Integer.bitCount(f.getChannelMask());
            if (offered.length() > 0) {
                offered.append(", ");
            }
            offered.append(f.getSampleRate()).append('/')
                    .append(encodingLabel(f.getEncoding())).append('/')
                    .append(ch).append("ch");
            if (match == null
                    && f.getSampleRate() == sampleRate
                    && f.getEncoding() == wantEncoding
                    && ch == channelCount) {
                match = a;
            }
        }
        if (match == null) {
            return reply(
                    "unsupportedByDevice",
                    offered.length() == 0 ? "no bit-perfect mixer attributes" : offered.toString());
        }

        final AudioAttributes attrs = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build();
        final boolean ok = audioManager.setPreferredMixerAttributes(attrs, usb, match);
        if (!ok) {
            return reply("failed", "setPreferredMixerAttributes returned false");
        }
        appliedAttributes = attrs;
        appliedDevice = usb;
        Map<String, Object> m = reply("enabled", null);
        CharSequence name = usb.getProductName();
        if (name != null) {
            m.put("deviceName", name.toString());
        }
        m.put("sampleRate", match.getFormat().getSampleRate());
        return m;
    }

    @RequiresApi(34)
    private void clearInternal() {
        final AudioAttributes attrs = appliedAttributes;
        final AudioDeviceInfo device = appliedDevice;
        appliedAttributes = null;
        appliedDevice = null;
        if (attrs == null || device == null) {
            return;
        }
        try {
            AudioManager am = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            if (am != null) {
                am.clearPreferredMixerAttributes(attrs, device);
            }
        } catch (Throwable ignored) {
            // 设备已拔出等：属性随设备消失，无需处理。
        }
    }
}
