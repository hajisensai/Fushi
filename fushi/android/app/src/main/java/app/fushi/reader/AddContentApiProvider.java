package app.fushi.reader;

import android.content.Context;

import com.ichi2.anki.api.AddContentApi;
import com.ichi2.anki.api.NoteInfo;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 主包 {@code com.ichi2.anki} 用的 {@link AnkiProvider}：逐行委托给上游 AAR 的
 * {@code AddContentApi}（BUG-2195）。
 *
 * <p><b>这里不许有任何逻辑</b>。它存在的唯一目的，是让「支持并行版」这件事**一行
 * 都不碰**今天所有 Android 用户在走的那条路——每个方法都必须是一次直白的转发，
 * 唯一的加工是把 AAR 的 {@code NoteInfo} 换成我们自己的 {@link AnkiNote}（并行版
 * 造不出 {@code NoteInfo}，见那个类的说明）。
 */
final class AddContentApiProvider implements AnkiProvider {

    private final AddContentApi api;

    AddContentApiProvider(Context context) {
        this.api = new AddContentApi(context);
    }

    private static AnkiNote wrap(NoteInfo note) {
        return note == null
            ? null
            : new AnkiNote(note.getId(), note.getFields(), note.getTags());
    }

    @Override
    public Map<Long, String> getDeckList() {
        return api.getDeckList();
    }

    @Override
    public Map<Long, String> getModelList(int minNumFields) {
        return minNumFields <= 0 ? api.getModelList() : api.getModelList(minNumFields);
    }

    @Override
    public String getModelName(long modelId) {
        return api.getModelName(modelId);
    }

    @Override
    public String[] getFieldList(long modelId) {
        return api.getFieldList(modelId);
    }

    @Override
    public String getDeckName(long deckId) {
        return api.getDeckName(deckId);
    }

    @Override
    public Long addNewDeck(String deckName) {
        return api.addNewDeck(deckName);
    }

    @Override
    public Long addNote(long modelId, long deckId, String[] fields, Set<String> tags) {
        return api.addNote(modelId, deckId, fields, tags);
    }

    @Override
    public AnkiNote getNote(long noteId) {
        return wrap(api.getNote(noteId));
    }

    @Override
    public boolean updateNoteFields(long noteId, String[] fields) {
        return api.updateNoteFields(noteId, fields);
    }

    @Override
    public List<AnkiNote> findDuplicateNotes(long modelId, String key) {
        final List<NoteInfo> found = api.findDuplicateNotes(modelId, key);
        if (found == null) return null;
        final List<AnkiNote> notes = new ArrayList<>(found.size());
        for (final NoteInfo note : found) {
            notes.add(wrap(note));
        }
        return notes;
    }

    @Override
    public Long addNewCustomModel(String name, String[] fields, String[] cards,
                                  String[] qfmt, String[] afmt, String css,
                                  Long deckId, Integer sortFieldIndex) {
        return api.addNewCustomModel(name, fields, cards, qfmt, afmt, css,
            deckId, sortFieldIndex);
    }
}
