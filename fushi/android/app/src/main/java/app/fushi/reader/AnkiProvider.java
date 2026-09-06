package app.fushi.reader;

import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * 对 AnkiDroid flashcards ContentProvider 的调用面（BUG-2195）。
 *
 * <p>只有两个实现，差别**仅仅**是 provider authority 从哪来：
 * <ul>
 *   <li>{@link AddContentApiProvider}：主包 {@code com.ichi2.anki}，直接委托给
 *       上游 AAR 的 {@code AddContentApi}。逐行委托、零行为改动——这条是今天所有
 *       Android 用户在走的路，不能因为支持并行版而让它承担任何风险。</li>
 *   <li>{@link DirectAnkiProvider}：并行版（{@code com.ichi2.anki.A} 等）。AAR 把
 *       {@code content://com.ichi2.anki.flashcards} 和权限名都编译成了常量（解包
 *       该 AAR 的常量池核对过），没有任何注入点，所以并行版只能自己驱动
 *       ContentResolver。</li>
 * </ul>
 *
 * <p><b>这是显式的临时兼容层</b>，理由是外部依赖不可改：上游 AAR 的 authority 是
 * 编译期常量。清理条件很明确——等 {@link DirectAnkiProvider} 在真机上把「建卡组 /
 * 建笔记类型 / 加笔记 / 查重 / 改字段」全部验证过之后，把主包也切到它、删掉
 * {@link AddContentApiProvider} 与对 AAR 的依赖，两条路合并成一条。
 */
public interface AnkiProvider {

    /** {@code deckId -> deckName}。 */
    Map<Long, String> getDeckList();

    /** {@code modelId -> modelName}，字段数不少于 {@code minNumFields}（0 = 不限）。 */
    Map<Long, String> getModelList(int minNumFields);

    /** 笔记类型名；不存在返回 null。 */
    String getModelName(long modelId);

    /** 笔记类型的字段名，按字段顺序；不存在返回 null。 */
    String[] getFieldList(long modelId);

    /** 卡组名；不存在返回 null。 */
    String getDeckName(long deckId);

    /** 新建卡组，返回 deckId；失败返回 null。 */
    Long addNewDeck(String deckName);

    /** 加一条笔记，返回 noteId；失败返回 null。 */
    Long addNote(long modelId, long deckId, String[] fields, Set<String> tags);

    /** 读一条笔记；不存在返回 null。 */
    AnkiNote getNote(long noteId);

    /** 整体覆盖一条笔记的字段（按笔记类型的字段顺序）。 */
    boolean updateNoteFields(long noteId, String[] fields);

    /**
     * 找出 {@code modelId} 下首字段等于 {@code key} 的笔记。
     *
     * <p>返回空列表 = 确实没有；返回 {@code null} = **查不了**（调用方必须把它与
     * 「没有重复」区分开，否则会静默造出重复卡）。
     */
    List<AnkiNote> findDuplicateNotes(long modelId, String key);

    /**
     * 新建自定义笔记类型，返回 modelId；失败返回 null。
     *
     * <p>{@code cards} / {@code qfmt} / {@code afmt} 三个数组必须等长（每张卡片模板
     * 一组）。
     */
    Long addNewCustomModel(String name, String[] fields, String[] cards,
                           String[] qfmt, String[] afmt, String css,
                           Long deckId, Integer sortFieldIndex);
}
