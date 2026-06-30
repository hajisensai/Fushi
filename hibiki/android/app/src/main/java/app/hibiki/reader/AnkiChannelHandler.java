package app.hibiki.reader;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.database.Cursor;
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
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
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
                final Number noteIdArg = call.argument("noteId");
                final Map<String, String> fieldValues = call.argument("fieldValues");

                switch (call.method) {
                    case "addNote":
                        if (model == null || deck == null) {
                            result.error("MISSING_ARG",
                                "model and deck are required", null);
                        } else if (fields == null || fields.isEmpty()) {
                            result.error("INVALID_FIELDS",
                                "fields is null or empty", null);
                        } else {
                            try {
                                // TODO-270 B：返回新建 note 的真实 id（Long），供
                                // Dart 端 MineOutcome.success(noteId:) 携带，弹窗据此
                                // 进入「最新可改」第三态、后续 updateNoteFields 覆盖。
                                Long newNoteId = addNote(model, deck, fields, tags);
                                if (newNoteId == null) {
                                    result.error("ADD_NOTE_FAILED",
                                        "AnkiDroid returned no note id "
                                            + "(duplicate or note type not found)",
                                        null);
                                } else {
                                    result.success(newNoteId);
                                }
                            } catch (IllegalStateException e) {
                                // addNote throws this when the note type is missing.
                                result.error("ADD_NOTE_FAILED", e.getMessage(), null);
                            }
                        }
                        break;
                    case "notesInfo":
                        // TODO-270 C2：读取一个 note 的现有字段（字段名 -> 值）。
                        if (noteIdArg == null) {
                            result.error("MISSING_ARG", "noteId is required", null);
                        } else if (requirePermission(result)) {
                            try {
                                result.success(notesInfo(noteIdArg.longValue()));
                            } catch (Exception e) {
                                result.error(providerErrorCode(e),
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "updateNoteFields":
                        // TODO-270 C2：按 noteId 覆盖给定字段（名 -> 值），其余字段保留。
                        if (noteIdArg == null || fieldValues == null) {
                            result.error("MISSING_ARG",
                                "noteId and fieldValues are required", null);
                        } else if (requirePermission(result)) {
                            try {
                                String updateError = updateNoteFields(
                                    noteIdArg.longValue(), fieldValues);
                                if (updateError != null) {
                                    result.error("UPDATE_NOTE_FAILED",
                                        updateError, null);
                                } else {
                                    result.success(null);
                                }
                            } catch (Exception e) {
                                result.error(providerErrorCode(e),
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "findNotesByContent":
                        // TODO-1007/1008：按内容（第一字段 = key，可选 reading 过滤）反查
                        // 所有同词卡的 note id + 一行预览，使 AnkiDroid 与桌面 AnkiConnect
                        // 一样能发现「别处/上次会话建的卡」。经 ContentProvider
                        // findDuplicateNotes(mid, key) -> NoteInfo.getId()，不依赖 bool-only
                        // 的 checkForDuplicates。
                        if (models == null || key == null) {
                            result.error("MISSING_ARG",
                                "models and key are required", null);
                        } else if (requirePermission(result)) {
                            new Handler(Looper.getMainLooper()).post(() -> {
                                try {
                                    result.success(findNotesByContent(
                                        models, key, reading, readingFieldIndices));
                                } catch (Exception e) {
                                    result.error(providerErrorCode(e),
                                        e.getMessage(), null);
                                }
                            });
                        }
                        break;
                    case "openNote":
                        // TODO-1007/1008：用 ACTION_VIEW intent 在 AnkiDroid 中打开该 note。
                        if (noteIdArg == null) {
                            result.error("MISSING_ARG", "noteId is required", null);
                        } else {
                            try {
                                result.success(openNote(noteIdArg.longValue()));
                            } catch (Exception e) {
                                result.error("OPEN_NOTE_FAILED",
                                    e.getMessage(), null);
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
                                result.error(providerErrorCode(e),
                                    e.getMessage(), null);
                            }
                        }
                        break;
                    case "getModelList":
                        if (requirePermission(result)) {
                            try {
                                result.success(api.getModelList());
                            } catch (Exception e) {
                                result.error(providerErrorCode(e),
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
                                result.error(providerErrorCode(e),
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
                        // TODO-1012 / BUG-474: filename 多来自 Dart 的
                        // Directory.systemTemp/anki-media（Android = code_cache）。FileProvider
                        // 的 provider_paths.xml 必须声明覆盖 code_cache 的根（<files-path
                        // path="../code_cache">），否则 getUriForFile 抛
                        // IllegalArgumentException「Failed to find configured root」，SVG 外字
                        // 制卡断裂。
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

    /**
     * TODO-292: classify an exception thrown by AnkiDroid's {@link AddContentApi}
     * ContentProvider client. When the collection database cannot be opened
     * (collection in use / mid-sync / corrupt, AnkiDroid never opened once, API
     * disabled, background process killed) AnkiDroid throws with the literal
     * message {@code "collection is not available"}. Surface that as a dedicated
     * {@code ANKI_COLLECTION_UNAVAILABLE} code so the Dart layer can show a
     * localized, actionable hint instead of the raw English text. All other
     * failures keep the generic {@code ANKI_PROVIDER_ERROR} code.
     */
    private String providerErrorCode(Exception e) {
        final String message = e.getMessage();
        if (message != null
                && message.toLowerCase().contains("collection is not available")) {
            return "ANKI_COLLECTION_UNAVAILABLE";
        }
        return "ANKI_PROVIDER_ERROR";
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

    /**
     * Adds a note via {@link AddContentApi#addNote} and returns the new note id.
     *
     * <p>TODO-270 B: AnkiDroid addNote returns the {@code Long} id of the newly
     * created note (or {@code null} if it refused to create one - e.g. a
     * duplicate the collection rejected). We surface that id all the way back to
     * {@code MineOutcome.noteId} so the popup can later overwrite this exact note
     * by id (symmetric with the AnkiConnect backend).
     *
     * @throws IllegalStateException if the note type cannot be found.
     */
    private Long addNote(String model, String deck,
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
            throw new IllegalStateException("Note type not found: " + model);
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

        return api.addNote(modelId, deckId, fields.toArray(new String[0]), allTags);
    }

    /**
     * TODO-270 C2: reads an existing note's fields as a {@code name -> value}
     * map (symmetric with the AnkiConnect notesInfo contract).
     *
     * <p>AnkiDroid is positional: {@link NoteInfo#getFields()} is an array in the
     * note's model field order, with no field names attached. We resolve the
     * note's model id (via the {@code Note.MID} column) and zip its field-name
     * list ({@link AddContentApi#getFieldList}) with the positional values.
     *
     * @return {@code name -> value} (insertion-ordered by field order), or
     *         {@code null} if the note no longer exists / its model is gone.
     */
    private Map<String, String> notesInfo(long noteId) {
        final AddContentApi api = new AddContentApi(activity);
        NoteInfo note = api.getNote(noteId);
        if (note == null) {
            return null;
        }
        String[] fieldNames = fieldNamesForNote(api, noteId);
        if (fieldNames == null) {
            return null;
        }
        String[] values = note.getFields();
        Map<String, String> result = new LinkedHashMap<>();
        for (int i = 0; i < fieldNames.length && i < values.length; i++) {
            result.put(fieldNames[i], values[i] == null ? "" : values[i]);
        }
        return result;
    }

    /**
     * TODO-270 C2: overwrites only the given fields of an existing note,
     * preserving every field the caller did not name (symmetric with the
     * AnkiConnect updateNoteFields contract).
     *
     * <p>{@link AddContentApi#updateNoteFields} takes a positional
     * {@code String[]} keyed by the model's field order. We start from the note's
     * current values and overwrite only the named ones, so unspecified fields are
     * not cleared.
     *
     * @return {@code null} on success, or a human-readable error string when the
     *         note / its model cannot be found or AnkiDroid refused the update.
     */
    private String updateNoteFields(long noteId, Map<String, String> fieldValues) {
        final AddContentApi api = new AddContentApi(activity);
        NoteInfo note = api.getNote(noteId);
        if (note == null) {
            return "Note not found: " + noteId;
        }
        String[] fieldNames = fieldNamesForNote(api, noteId);
        if (fieldNames == null) {
            return "Note type not found for note: " + noteId;
        }
        // Start from the existing values so unspecified fields are preserved
        // (overwrite-given-fields-only semantics).
        String[] existing = note.getFields();
        String[] merged = new String[fieldNames.length];
        for (int i = 0; i < fieldNames.length; i++) {
            String value = fieldValues.get(fieldNames[i]);
            if (value != null) {
                merged[i] = value;
            } else if (i < existing.length && existing[i] != null) {
                merged[i] = existing[i];
            } else {
                merged[i] = "";
            }
        }
        boolean ok = api.updateNoteFields(noteId, merged);
        return ok ? null : "AnkiDroid rejected the field update for note " + noteId;
    }

    /**
     * Resolves the field-name list (in field order) for the model that owns
     * noteId. {@link NoteInfo} carries no model id, so we read the note's
     * {@code Note.MID} column from the ContentProvider, then ask
     * {@link AddContentApi#getFieldList} for that model's field names.
     *
     * @return the field names in order, or {@code null} if the note / model is
     *         not resolvable.
     */
    private String[] fieldNamesForNote(AddContentApi api, long noteId) {
        Long modelId = modelIdForNote(noteId);
        if (modelId == null) {
            return null;
        }
        return api.getFieldList(modelId);
    }

    /**
     * Reads the {@code mid} (model id) column of a note from AnkiDroid's
     * {@link FlashCardsContract.Note} ContentProvider. Returns {@code null} if
     * the note does not exist or the provider yields no row.
     */
    private Long modelIdForNote(long noteId) {
        ContentResolver resolver = activity.getContentResolver();
        Uri noteUri = Uri.withAppendedPath(
            FlashCardsContract.Note.CONTENT_URI, Long.toString(noteId));
        try (Cursor cursor = resolver.query(
                noteUri,
                new String[]{FlashCardsContract.Note.MID},
                null, null, null)) {
            if (cursor == null || !cursor.moveToFirst()) {
                return null;
            }
            int midIndex = cursor.getColumnIndex(FlashCardsContract.Note.MID);
            if (midIndex < 0 || cursor.isNull(midIndex)) {
                return null;
            }
            return cursor.getLong(midIndex);
        }
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

    /**
     * TODO-1007/1008: find every note whose first field equals {@code key}
     * (optionally also matching {@code reading} at the given field index) and
     * return a list of {@code {noteId, preview}} maps, ordered newest-first
     * (AnkiDroid note ids are creation-epoch longs, larger = newer).
     *
     * <p>This is the AnkiDroid analogue of the AnkiConnect findNotes + notesInfo
     * path: it discovers cards created anywhere (other apps, previous sessions),
     * not just the current popup session. {@link AddContentApi#findDuplicateNotes}
     * gives the matching {@link NoteInfo}s; {@link NoteInfo#getId()} is the note
     * id and {@link NoteInfo#getFields()}[0] (HTML-stripped on the Dart side) is
     * the preview.
     *
     * @return a list of {@code LinkedHashMap{noteId:Long, preview:String}},
     *         newest-first; empty when nothing matches.
     */
    private List<Map<String, Object>> findNotesByContent(
            ArrayList<String> models, String key, String reading,
            ArrayList<Integer> readingFieldIndices) {
        final AddContentApi api = new AddContentApi(activity);
        // De-dup by note id across models (a card matches at most one model, but
        // guard anyway), then sort newest-first.
        final LinkedHashMap<Long, String> byId = new LinkedHashMap<>();
        for (int i = 0; i < models.size(); i++) {
            String model = models.get(i);
            Long mid = ankiDroid.findModelIdByName(model, 1);
            if (mid == null) continue;
            List<NoteInfo> notes = api.findDuplicateNotes(mid, key);
            if (notes == null || notes.isEmpty()) continue;
            int readingIdx = (readingFieldIndices != null && i < readingFieldIndices.size())
                    ? readingFieldIndices.get(i) : -1;
            for (NoteInfo note : notes) {
                String[] noteFields = note.getFields();
                // When a reading is supplied and the model has a reading field,
                // keep only notes whose reading also matches (mirrors the dupe
                // check). Otherwise accept on the first-field match alone.
                if (reading != null && !reading.isEmpty() && readingIdx >= 0) {
                    if (readingIdx >= noteFields.length
                            || !reading.equals(noteFields[readingIdx])) {
                        continue;
                    }
                }
                long id = note.getId();
                String preview = noteFields.length > 0 && noteFields[0] != null
                        ? noteFields[0] : "";
                byId.put(id, preview);
            }
        }
        List<Long> ids = new ArrayList<>(byId.keySet());
        ids.sort((a, b) -> Long.compare(b, a)); // newest (larger id) first
        List<Map<String, Object>> out = new ArrayList<>(ids.size());
        for (Long id : ids) {
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("noteId", id);
            entry.put("preview", byId.get(id));
            out.add(entry);
        }
        return out;
    }

    /**
     * TODO-1007/1008: open the given note in AnkiDroid via an {@code ACTION_VIEW}
     * intent on the note's ContentProvider URI. Returns {@code true} when an
     * activity was launched, {@code false} when no app could handle it.
     */
    private boolean openNote(long noteId) {
        Uri noteUri = Uri.withAppendedPath(
            FlashCardsContract.Note.CONTENT_URI, Long.toString(noteId));
        Intent intent = new Intent(Intent.ACTION_VIEW, noteUri);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        if (intent.resolveActivity(activity.getPackageManager()) == null) {
            return false;
        }
        activity.startActivity(intent);
        return true;
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
