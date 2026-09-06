package app.fushi.reader;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.text.TextUtils;

import com.ichi2.anki.FlashCardsContract;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * 并行版 AnkiDroid（{@code com.ichi2.anki.A} 等）用的 {@link AnkiProvider}：自己驱动
 * ContentResolver，authority 来自 {@link AnkiDroidTarget}（BUG-2195）。
 *
 * <p>为什么必须自己写：上游 AAR 把 {@code content://com.ichi2.anki.flashcards} 编译
 * 成了 {@code FlashCardsContract} 的常量，{@code AddContentApi} 的每一个 URI 都由它
 * 派生，没有任何注入点（解包 {@code Anki-Android-2.17alpha14.aar} 的常量池逐一核对
 * 过）。而并行版的 authority 是 {@code ${applicationId}.flashcards}，对不上。
 *
 * <p><b>列名、path 段、query 参数全部复用 {@code FlashCardsContract} 的常量</b>——
 * 它们不带包名，是 provider 契约的一部分，与装的是哪一份无关。这里改的只有
 * authority 一处，所以「契约漂移」的风险和主包路径是同一个量级。
 */
final class DirectAnkiProvider implements AnkiProvider {

    /** Anki 用来分隔一条笔记各字段的字符（0x1f，Unit Separator）。 */
    private static final String FIELD_SEPARATOR = "\u001f";

    private final ContentResolver resolver;
    private final AnkiDroidTarget target;

    DirectAnkiProvider(Context context, AnkiDroidTarget target) {
        this.resolver = context.getContentResolver();
        this.target = target;
    }

    // ── URI ────────────────────────────────────────────────────────────

    private Uri notes() {
        return target.rebase(FlashCardsContract.Note.CONTENT_URI);
    }

    private Uri notesV2() {
        return target.rebase(FlashCardsContract.Note.CONTENT_URI_V2);
    }

    private Uri note(long noteId) {
        return Uri.withAppendedPath(notes(), Long.toString(noteId));
    }

    private Uri models() {
        return target.rebase(FlashCardsContract.Model.CONTENT_URI);
    }

    private Uri model(long modelId) {
        return Uri.withAppendedPath(models(), Long.toString(modelId));
    }

    private Uri decks() {
        // Deck 的常量名与 Note/Model 不同步：它叫 CONTENT_ALL_URI
        // （另有 CONTENT_SELECTED_URI 指“当前选中的卡组”）。
        return target.rebase(FlashCardsContract.Deck.CONTENT_ALL_URI);
    }

    private Uri deck(long deckId) {
        return Uri.withAppendedPath(decks(), Long.toString(deckId));
    }

    // ── 卡组 ───────────────────────────────────────────────────────────

    @Override
    public Map<Long, String> getDeckList() {
        final Map<Long, String> result = new LinkedHashMap<>();
        final Cursor cursor = resolver.query(decks(), null, null, null, null);
        if (cursor == null) return result;
        try {
            final int idIdx = cursor.getColumnIndex(FlashCardsContract.Deck.DECK_ID);
            final int nameIdx = cursor.getColumnIndex(FlashCardsContract.Deck.DECK_NAME);
            if (idIdx < 0 || nameIdx < 0) return result;
            while (cursor.moveToNext()) {
                result.put(cursor.getLong(idIdx), cursor.getString(nameIdx));
            }
        } finally {
            cursor.close();
        }
        return result;
    }

    @Override
    public String getDeckName(long deckId) {
        final Cursor cursor = resolver.query(deck(deckId), null, null, null, null);
        if (cursor == null) return null;
        try {
            final int nameIdx = cursor.getColumnIndex(FlashCardsContract.Deck.DECK_NAME);
            if (nameIdx < 0 || !cursor.moveToFirst()) return null;
            return cursor.getString(nameIdx);
        } finally {
            cursor.close();
        }
    }

    @Override
    public Long addNewDeck(String deckName) {
        final ContentValues values = new ContentValues();
        values.put(FlashCardsContract.Deck.DECK_NAME, deckName);
        final Uri inserted = resolver.insert(decks(), values);
        return lastPathAsLong(inserted);
    }

    // ── 笔记类型 ───────────────────────────────────────────────────────

    @Override
    public Map<Long, String> getModelList(int minNumFields) {
        final Map<Long, String> result = new LinkedHashMap<>();
        final Cursor cursor = resolver.query(models(), null, null, null, null);
        if (cursor == null) return result;
        try {
            final int idIdx = cursor.getColumnIndex(FlashCardsContract.Model._ID);
            final int nameIdx = cursor.getColumnIndex(FlashCardsContract.Model.NAME);
            final int fieldsIdx =
                cursor.getColumnIndex(FlashCardsContract.Model.FIELD_NAMES);
            if (idIdx < 0 || nameIdx < 0) return result;
            while (cursor.moveToNext()) {
                if (minNumFields > 0 && fieldsIdx >= 0) {
                    final String[] names = splitFields(cursor.getString(fieldsIdx));
                    if (names.length < minNumFields) continue;
                }
                result.put(cursor.getLong(idIdx), cursor.getString(nameIdx));
            }
        } finally {
            cursor.close();
        }
        return result;
    }

    @Override
    public String getModelName(long modelId) {
        final Cursor cursor = resolver.query(model(modelId), null, null, null, null);
        if (cursor == null) return null;
        try {
            final int nameIdx = cursor.getColumnIndex(FlashCardsContract.Model.NAME);
            if (nameIdx < 0 || !cursor.moveToFirst()) return null;
            return cursor.getString(nameIdx);
        } finally {
            cursor.close();
        }
    }

    @Override
    public String[] getFieldList(long modelId) {
        final Cursor cursor = resolver.query(model(modelId), null, null, null, null);
        if (cursor == null) return null;
        try {
            final int fieldsIdx =
                cursor.getColumnIndex(FlashCardsContract.Model.FIELD_NAMES);
            if (fieldsIdx < 0 || !cursor.moveToFirst()) return null;
            return splitFields(cursor.getString(fieldsIdx));
        } finally {
            cursor.close();
        }
    }

    @Override
    public Long addNewCustomModel(String name, String[] fields, String[] cards,
                                  String[] qfmt, String[] afmt, String css,
                                  Long deckId, Integer sortFieldIndex) {
        if (cards == null || qfmt == null || afmt == null
            || cards.length != qfmt.length || cards.length != afmt.length) {
            throw new IllegalArgumentException(
                "cards, qfmt, and afmt arrays must all be same length");
        }
        final ContentValues values = new ContentValues();
        values.put(FlashCardsContract.Model.NAME, name);
        values.put(FlashCardsContract.Model.FIELD_NAMES, joinFields(fields));
        values.put(FlashCardsContract.Model.NUM_CARDS, cards.length);
        if (css != null) values.put(FlashCardsContract.Model.CSS, css);
        if (deckId != null) values.put(FlashCardsContract.Model.DECK_ID, deckId);
        if (sortFieldIndex != null) {
            values.put(FlashCardsContract.Model.SORT_FIELD_INDEX, sortFieldIndex);
        }
        final Long modelId = lastPathAsLong(resolver.insert(models(), values));
        if (modelId == null) return null;

        // 模板逐张写：`models/<mid>/templates/<ord>`。笔记类型建出来时模板是占位的，
        // 不写这一步卡片正反面就是空的。
        final Uri templates = Uri.withAppendedPath(model(modelId), "templates");
        for (int ord = 0; ord < cards.length; ord++) {
            final ContentValues template = new ContentValues();
            template.put(FlashCardsContract.CardTemplate.NAME, cards[ord]);
            template.put(FlashCardsContract.CardTemplate.QUESTION_FORMAT, qfmt[ord]);
            template.put(FlashCardsContract.CardTemplate.ANSWER_FORMAT, afmt[ord]);
            resolver.update(
                Uri.withAppendedPath(templates, Integer.toString(ord)),
                template, null, null);
        }
        return modelId;
    }

    // ── 笔记 ───────────────────────────────────────────────────────────

    @Override
    public Long addNote(long modelId, long deckId, String[] fields, Set<String> tags) {
        final ContentValues values = new ContentValues();
        values.put(FlashCardsContract.Note.MID, modelId);
        values.put(FlashCardsContract.Note.FLDS, joinFields(fields));
        if (tags != null && !tags.isEmpty()) {
            values.put(FlashCardsContract.Note.TAGS, TextUtils.join(" ", tags));
        }
        // 卡组不是笔记的列，是插入时的 query 参数（契约常量 DECK_ID_QUERY_PARAM）。
        final Uri target = notes().buildUpon()
            .appendQueryParameter(
                FlashCardsContract.Note.DECK_ID_QUERY_PARAM, Long.toString(deckId))
            .build();
        return lastPathAsLong(resolver.insert(target, values));
    }

    @Override
    public AnkiNote getNote(long noteId) {
        final Cursor cursor = resolver.query(note(noteId), null, null, null, null);
        if (cursor == null) return null;
        try {
            if (!cursor.moveToFirst()) return null;
            return readNote(cursor, noteId);
        } finally {
            cursor.close();
        }
    }

    @Override
    public boolean updateNoteFields(long noteId, String[] fields) {
        final ContentValues values = new ContentValues();
        values.put(FlashCardsContract.Note.FLDS, joinFields(fields));
        return resolver.update(note(noteId), values, null, null) > 0;
    }

    /**
     * 查重走 {@code notes_v2} 的 {@code mid=? and csum in (?)}——与上游 AAR 的
     * spec-2 实现同一条路（它的格式串 {@code "%s=%d and %s in (%s)"} 就在 AAR 的
     * 常量池里）。csum 只是个哈希桶，命中后仍必须逐条比首字段，这一点也与上游一致。
     *
     * <p>算不出 csum（理论上不会发生，SHA-1 是 JDK 必备算法）时返回 {@code null}
     * 而不是空列表：调用方据此把「查不了」与「没有重复」分开，否则会静默造重复卡。
     */
    @Override
    public List<AnkiNote> findDuplicateNotes(long modelId, String key) {
        final Long checksum = fieldChecksum(key);
        if (checksum == null) return null;
        final String selection = String.format(
            Locale.US, "%s=%d and %s in (%d)",
            FlashCardsContract.Note.MID, modelId,
            FlashCardsContract.Note.CSUM, checksum);
        final Cursor cursor = resolver.query(notesV2(), null, selection, null, null);
        if (cursor == null) return null;
        final List<AnkiNote> matches = new ArrayList<>();
        try {
            while (cursor.moveToNext()) {
                final AnkiNote candidate = readNote(cursor, -1L);
                if (candidate == null) continue;
                final String[] noteFields = candidate.getFields();
                if (noteFields.length > 0 && key.equals(noteFields[0])) {
                    matches.add(candidate);
                }
            }
        } finally {
            cursor.close();
        }
        return matches;
    }

    // ── 工具 ───────────────────────────────────────────────────────────

    private static AnkiNote readNote(Cursor cursor, long fallbackId) {
        final int idIdx = cursor.getColumnIndex(FlashCardsContract.Note._ID);
        final int fldsIdx = cursor.getColumnIndex(FlashCardsContract.Note.FLDS);
        final int tagsIdx = cursor.getColumnIndex(FlashCardsContract.Note.TAGS);
        final long id = idIdx >= 0 ? cursor.getLong(idIdx) : fallbackId;
        if (id < 0) return null;
        final String[] fields =
            fldsIdx >= 0 ? splitFields(cursor.getString(fldsIdx)) : new String[0];
        Set<String> tags = Collections.emptySet();
        if (tagsIdx >= 0) {
            final String raw = cursor.getString(tagsIdx);
            if (raw != null && !raw.trim().isEmpty()) {
                tags = new HashSet<>(Arrays.asList(raw.trim().split("\\s+")));
            }
        }
        return new AnkiNote(id, fields, tags);
    }

    private static String[] splitFields(String flds) {
        if (flds == null) return new String[0];
        return flds.split(FIELD_SEPARATOR, -1);
    }

    private static String joinFields(String[] fields) {
        if (fields == null) return "";
        return TextUtils.join(FIELD_SEPARATOR, fields);
    }

    private static Long lastPathAsLong(Uri uri) {
        if (uri == null) return null;
        final String last = uri.getLastPathSegment();
        if (last == null) return null;
        try {
            return Long.parseLong(last);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /**
     * Anki 的字段校验和：首字段 SHA-1 的**前 8 个 hex 字符**当作无符号整数。
     *
     * <p>上游在算之前会先剥掉 HTML 与媒体标签；本 app 传进来的查重 key 是查词得到的
     * 词条原文（纯文本），剥不剥结果相同。真有 HTML 时最坏结果是**算不中**（查不到
     * 重复），绝不会误报成重复——这个方向的错误是安全的。
     */
    private static Long fieldChecksum(String field) {
        if (field == null) return null;
        try {
            final MessageDigest digest = MessageDigest.getInstance("SHA-1");
            final byte[] hash = digest.digest(field.getBytes("UTF-8"));
            final StringBuilder hex = new StringBuilder();
            for (int i = 0; i < 4 && i < hash.length; i++) {
                hex.append(String.format(Locale.US, "%02x", hash[i]));
            }
            return Long.parseLong(hex.toString(), 16);
        } catch (NoSuchAlgorithmException | java.io.UnsupportedEncodingException e) {
            return null;
        }
    }
}
