package app.fushi.reader;

import java.util.Collections;
import java.util.Set;

/**
 * 一条 Anki 笔记的最小快照（BUG-2195）。
 *
 * <p>为什么不直接用 AAR 的 {@code com.ichi2.anki.api.NoteInfo}：它没有公开构造函数
 * （只有 Kotlin 生成的合成构造和 {@code buildFromCursor$api_release} 这个 internal
 * 方法），并行版走的 {@link DirectAnkiProvider} 自己读 cursor，造不出它。用自己的
 * DTO 让两个 {@link AnkiProvider} 实现返回同一种类型，调用方因此完全不需要知道
 * 底下是哪一条路。
 */
public final class AnkiNote {

    private final long id;
    private final String[] fields;
    private final Set<String> tags;

    public AnkiNote(long id, String[] fields, Set<String> tags) {
        this.id = id;
        this.fields = fields == null ? new String[0] : fields;
        this.tags = tags == null ? Collections.<String>emptySet() : tags;
    }

    public long getId() {
        return id;
    }

    public String[] getFields() {
        return fields;
    }

    public Set<String> getTags() {
        return tags;
    }
}
