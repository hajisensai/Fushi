package app.hibiki.reader;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.core.content.FileProvider;

import com.ichi2.anki.FlashCardsContract;
import com.ichi2.anki.api.AddContentApi;
import com.ichi2.anki.api.NoteInfo;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import app.hibiki.reader.constants.ChannelNames;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class AnkiChannelHandler {
    private static final String CHANNEL = ChannelNames.ANKI;
    private static final int AD_PERM_REQUEST = 0;

    private final Activity activity;
    private final AnkiDroidHelper ankiDroid;

    public AnkiChannelHandler(Activity activity) {
        this.activity = activity;
        this.ankiDroid = new AnkiDroidHelper(activity);
    }

    public void register(@NonNull FlutterEngine engine) {
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), CHANNEL)
            .setMethodCallHandler((call, result) -> {
                final String model = call.argument("model");
                final String deck = call.argument("deck");
                final String key = call.argument("key");
                final String reading = call.argument("reading");
                final ArrayList<Integer> readingFieldIndices = call.argument("readingFieldIndices");
                final ArrayList<String> fields = call.argument("fields");
                final ArrayList<String> tags = call.argument("tags");
                final ArrayList<String> models = call.argument("models");
                final String filename = call.argument("filename");
                final String preferredName = call.argument("preferredName");
                final String mimeType = call.argument("mimeType");
                final AddContentApi api = new AddContentApi(activity);
                final ArrayList<String> noteTypeFields = call.argument("noteTypeFields");
                final String noteTypeName = call.argument("noteTypeName");
                final String cardName = call.argument("cardName");
                final String front = call.argument("front");
                final String back = call.argument("back");
                final String css = call.argument("css");
                final String deckName = call.argument("deckName");

                switch (call.method) {
                    case "addNote":
                        if (model == null || deck == null) {
                            result.error("MISSING_ARG",
                                "model and deck are required", null);
                        } else if (fields == null || fields.isEmpty()) {
                            result.error("INVALID_FIELDS",
                                "fields is null or empty", null);
                        } else {
                            String addError = addNote(model, deck, fields, tags);
                            if (addError != null) {
                                result.error("ADD_NOTE_FAILED", addError, null);
                            } else {
                                result.success("Added note");
                            }
                        }
                        break;
                    case "checkForDuplicates":
                        if (models == null || key == null) {
                            result.error("MISSING_ARG",
                                "models and key are required", null);
                        } else if (ankiDroid.shouldRequestPermission()) {
                            result.success(false);
                        } else {
                            // HBK-AUDIT-020: the dupe-check queries the AnkiDroid
                            // ContentProvider, which can throw (provider disabled
                            // mid-session, SecurityException, null cursor). Without
                            // this guard the exception escaped the posted Runnable
                            // and the Dart Future never completed (hang). Always
                            // complete the result.
                            new Handler(Looper.getMainLooper()).post(() -> {
                                try {
                                    result.success(checkForDuplicates(
                                        models, key, reading, readingFieldIndices));
                                } catch (Exception e) {
                                    result.error("DUPE_CHECK_FAILED",
                                        e.getMessage(), null);
                                }
                            });
                        }
                        break;
                    case "getDecks":
                        if (requirePermission(result)) {
                            try {
                                result.success(api.getDeckList());
                            } catch (Exception e) {
                                result.error("ANKI_PROVIDER_ERROR",
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "getModelList":
                        if (requirePermission(result)) {
                            try {
                                result.success(api.getModelList());
                            } catch (Exception e) {
                                result.error("ANKI_PROVIDER_ERROR",
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "getFieldList":
                        if (model == null) {
                            result.error("MISSING_ARG",
                                "model is required", null);
                        } else if (requirePermission(result)) {
                            try {
                                Long mid = ankiDroid.findModelIdByName(model, 1);
                                if (mid == null) {
                                    result.error("MODEL_NOT_FOUND",
                                        "Note type not found: " + model, null);
                                } else {
                                    result.success(
                                        Arrays.asList(api.getFieldList(mid)));
                                }
                            } catch (Exception e) {
                                result.error("ANKI_PROVIDER_ERROR",
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "createNoteType":
                        if (noteTypeName == null || noteTypeFields == null
                                || noteTypeFields.isEmpty()) {
                            result.error("MISSING_ARG",
                                "noteTypeName and noteTypeFields are required", null);
                        } else if (requirePermission(result)) {
                            try {
                                createNoteType(noteTypeName, noteTypeFields,
                                    cardName, front, back, css);
                                result.success(null);
                            } catch (Exception e) {
                                result.error("CREATE_MODEL_FAILED",
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "createDeck":
                        if (deckName == null) {
                            result.error("MISSING_ARG",
                                "deckName is required", null);
                        } else if (requirePermission(result)) {
                            try {
                                if (ankiDroid.findDeckIdByName(deckName) == null) {
                                    api.addNewDeck(deckName);
                                }
                                result.success(null);
                            } catch (Exception e) {
                                result.error("CREATE_DECK_FAILED",
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "requestAnkidroidPermissions":
                        if (ankiDroid.shouldRequestPermission()) {
                            ankiDroid.requestPermission(activity, AD_PERM_REQUEST);
                        }
                        result.success(true);
                        break;
                    case "addFileToMedia":
                        if (filename == null || preferredName == null) {
                            result.error("MISSING_ARG",
                                "filename and preferredName are required", null);
                            break;
                        }
                        File file = new File(filename);
                        Uri fileUri = FileProvider.getUriForFile(
                            activity, BuildConfig.APPLICATION_ID + ".provider", file);
                        activity.grantUriPermission("com.ichi2.anki", fileUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION);
                        ContentValues contentValues = new ContentValues();
                        contentValues.put(FlashCardsContract.AnkiMedia.FILE_URI,
                            fileUri.toString());
                        contentValues.put(FlashCardsContract.AnkiMedia.PREFERRED_NAME,
                            preferredName);
                        ContentResolver contentResolver = activity.getContentResolver();
                        Uri returnUri = contentResolver.insert(
                            FlashCardsContract.AnkiMedia.CONTENT_URI, contentValues);
                        if (returnUri == null || returnUri.getPath() == null) {
                            result.error("MEDIA_INSERT_FAILED",
                                "AnkiDroid media insert returned null", null);
                        } else {
                            result.success(
                                new File(returnUri.getPath()).toString().substring(1));
                        }
                        break;
                    default:
                        result.notImplemented();
                }
            });
    }

    private boolean requirePermission(MethodChannel.Result result) {
        if (ankiDroid.shouldRequestPermission()) {
            ankiDroid.requestPermission(activity, AD_PERM_REQUEST);
            result.error("PERMISSION_DENIED",
                "AnkiDroid permission not granted. Please grant and retry.",
                null);
            return false;
        }
        return true;
    }

    private String addNote(String model, String deck,
                           ArrayList<String> fields, ArrayList<String> tags) {
        final AddContentApi api = new AddContentApi(activity);

        long deckId;
        Long existingDeck = ankiDroid.findDeckIdByName(deck);
        if (existingDeck != null) {
            deckId = existingDeck;
        } else {
            deckId = api.addNewDeck(deck);
        }

        Long modelIdObj = ankiDroid.findModelIdByName(model, fields.size());
        if (modelIdObj == null) {
            return "Note type not found: " + model;
        }
        long modelId = modelIdObj;

        // TODO-115: 旧 Yuuna fork 在此硬编码追加一个名为 Yuuna 的默认 tag（无特殊
        // 含义，仅旧应用名残留）。已移除——制卡的 `hibiki` 固定标签与 book/anime 分类标签
        // 现统一由 Dart 端 BaseAnkiRepository.buildNoteTags 计算后经 `tags` 传入，
        // 与 AnkiConnect 后端对称；这里只透传，不再注入任何后端专属默认 tag。
        Set<String> allTags = new HashSet<>();
        if (tags != null) {
            allTags.addAll(tags);
        }

        api.addNote(modelId, deckId, fields.toArray(new String[0]), allTags);
        return null;
    }

    private boolean checkForDuplicates(ArrayList<String> models, String key,
                                       String reading,
                                       ArrayList<Integer> readingFieldIndices) {
        final AddContentApi api = new AddContentApi(activity);
        for (int i = 0; i < models.size(); i++) {
            String model = models.get(i);
            Long mid = ankiDroid.findModelIdByName(model, 1);
            if (mid == null) continue;
            List<NoteInfo> notes = api.findDuplicateNotes(mid, key);
            if (notes.isEmpty()) continue;
            if (reading == null || reading.isEmpty()) return true;
            int readingIdx = (readingFieldIndices != null && i < readingFieldIndices.size())
                    ? readingFieldIndices.get(i) : -1;
            if (readingIdx < 0) return true;
            for (NoteInfo note : notes) {
                String[] noteFields = note.getFields();
                if (readingIdx < noteFields.length && reading.equals(noteFields[readingIdx])) {
                    return true;
                }
            }
        }
        return false;
    }

    private void createNoteType(String name, ArrayList<String> fields,
                                String cardName, String front, String back,
                                String css) {
        final AddContentApi api = new AddContentApi(activity);
        // Idempotent: a model with this name + field count already exists.
        if (ankiDroid.findModelIdByName(name, fields.size()) != null) return;
        api.addNewCustomModel(
            name,
            fields.toArray(new String[0]),
            new String[] { cardName },
            new String[] { front },
            new String[] { back },
            css,
            null,
            null
        );
    }
}
