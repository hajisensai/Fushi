// Derived from the AnkiDroid API Sample

package app.fushi.reader;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import android.util.SparseArray;


import java.util.ArrayList;
import java.util.LinkedList;
import java.util.List;
import java.util.ListIterator;
import java.util.Map;
import java.util.Set;

import static com.ichi2.anki.api.AddContentApi.READ_WRITE_PERMISSION;

public class AnkiDroidHelper {
    private static final String DECK_REF_DB = "com.ichi2.anki.api.decks";
    private static final String MODEL_REF_DB = "com.ichi2.anki.api.models";

    private AnkiProvider mApi;
    private Context mContext;

    public AnkiDroidHelper(Context context) {
        mContext = context.getApplicationContext();
        // BUG-2195：主包仍是 AddContentApi（逐行委托、行为不变），并行版走自建的
        // ContentResolver 实现。一个都没装时为 null——调用点在此之前都被
        // isApiAvailable 挡住了。
        mApi = AnkiProviders.forContext(mContext);
    }

    public AnkiProvider getApi() {
        return mApi;
    }

    /**
     * Whether or not the API is available to use.
     * The API could be unavailable if AnkiDroid is not installed or the user explicitly disabled the API
     *
     * <p>BUG-2195：判据从 {@code AddContentApi.getAnkiDroidPackageName}（只认写死的
     * 主包 authority {@code com.ichi2.anki.flashcards}）换成 {@link AnkiDroidTarget}
     * 的逐候选探测，否则装了并行版（{@code com.ichi2.anki.A} 等）的机器上这里恒
     * false，权限框一次都不会弹。
     *
     * @return true if the API is available to use
     */
    public static boolean isApiAvailable(Context context) {
        return AnkiDroidTarget.resolve(context) != null;
    }

    /**
     * 本设备上实际装的那份 AnkiDroid；一个都没有则 null。
     */
    public static AnkiDroidTarget target(Context context) {
        return AnkiDroidTarget.resolve(context);
    }

    /**
     * 要申请的读写权限名。BUG-2195：并行版定义的是**它自己**那个带后缀的权限
     * （{@code com.ichi2.anki.A.permission.READ_WRITE_DATABASE}），申请主包那个只会
     * 静默判拒。没解析到安装时回退主包常量——此时 shouldRequestPermission 的结果无人
     * 使用（isApiAvailable 已经先短路了）。
     */
    private String readWritePermission() {
        final AnkiDroidTarget resolved = AnkiDroidTarget.resolve(mContext);
        return resolved == null ? READ_WRITE_PERMISSION : resolved.permission;
    }

    /**
     * Whether or not we should request full access to the AnkiDroid API
     */
    public boolean shouldRequestPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return false;
        }
        return ContextCompat.checkSelfPermission(mContext, readWritePermission()) != PackageManager.PERMISSION_GRANTED;
    }

    /**
     * Request permission from the user to access the AnkiDroid API (for SDK 23+)
     * @param callbackActivity An Activity which implements onRequestPermissionsResult()
     * @param callbackCode The callback code to be used in onRequestPermissionsResult()
     */
    public void requestPermission(Activity callbackActivity, int callbackCode) {
        ActivityCompat.requestPermissions(callbackActivity, new String[]{readWritePermission()}, callbackCode);
    }

    /**
     * BUG-2098：被拒之后系统还愿不愿意再弹框。
     *
     * <p>刚被拒绝一次时 Android 会让 rationale 为 true（可以再问）；勾了「不再询问」
     * 或系统压根没弹（权限未被任何已安装包定义）时恒 false——那种情况下只能引导用户
     * 去应用设置页手动授予，再调 requestPermissions 只会立刻静默失败。
     */
    public boolean canAskPermissionAgain(Activity callbackActivity) {
        return ActivityCompat.shouldShowRequestPermissionRationale(
                callbackActivity, readWritePermission());
    }


    /**
     * Save a mapping from deckName to getDeckId in the SharedPreferences
     */
    public void storeDeckReference(String deckName, long deckId) {
        final SharedPreferences decksDb = mContext.getSharedPreferences(DECK_REF_DB, Context.MODE_PRIVATE);
        decksDb.edit().putLong(deckName, deckId).apply();
    }

    /**
     * Save a mapping from modelName to modelId in the SharedPreferences
     */
    public void storeModelReference(String modelName, long modelId) {
        final SharedPreferences modelsDb = mContext.getSharedPreferences(MODEL_REF_DB, Context.MODE_PRIVATE);
        modelsDb.edit().putLong(modelName, modelId).apply();
    }

    /**
     * Remove the duplicates from a list of note fields and tags
     * @param fields List of fields to remove duplicates from
     * @param tags List of tags to remove duplicates from
     * @param modelId ID of model to search for duplicates on
     */
    private SparseArray<List<AnkiNote>> findDuplicateNotesByKeys(
            long modelId, List<String> keys) {
        // BUG-2195：AnkiProvider 只暴露单 key 查重（两个实现都能可靠支持），多 key
        // 版在这里按 key 逐个查。本方法只服务下面那个从上游 sample 抄来的
        // removeDuplicates —— 它全仓无调用，保留只为不删上游对照代码。
        final SparseArray<List<AnkiNote>> result = new SparseArray<>();
        for (int i = 0; i < keys.size(); i++) {
            final List<AnkiNote> found = mApi.findDuplicateNotes(modelId, keys.get(i));
            if (found != null && !found.isEmpty()) {
                result.put(i, found);
            }
        }
        return result;
    }

    public void removeDuplicates(LinkedList<String []> fields, LinkedList<Set<String>> tags, long modelId) {
        // Build a list of the duplicate keys (first fields) and find all notes that have a match with each key
        List<String> keys = new ArrayList<>(fields.size());
        for (String[] f: fields) {
            keys.add(f[0]);
        }
        SparseArray<List<AnkiNote>> duplicateNotes = findDuplicateNotesByKeys(modelId, keys);
        // Do some sanity checks
        if (tags.size() != fields.size()) {
            throw new IllegalStateException("List of tags must be the same length as the list of fields");
        }
        if (duplicateNotes == null || duplicateNotes.size() == 0 || fields.size() == 0 || tags.size() == 0) {
            return;
        }
        if (duplicateNotes.keyAt(duplicateNotes.size() - 1) >= fields.size()) {
            throw new IllegalStateException("The array of duplicates goes outside the bounds of the original lists");
        }
        // Iterate through the fields and tags LinkedLists, removing those that had a duplicate
        ListIterator<String[]> fieldIterator = fields.listIterator();
        ListIterator<Set<String>> tagIterator = tags.listIterator();
        int listIndex = -1;
        for (int i = 0; i < duplicateNotes.size(); i++) {
            int duplicateIndex = duplicateNotes.keyAt(i);
            while (listIndex < duplicateIndex) {
                fieldIterator.next();
                tagIterator.next();
                listIndex++;
            }
            fieldIterator.remove();
            tagIterator.remove();
        }
    }


    /**
     * Try to find the given model by name, accounting for renaming of the model:
     * If there's a model with this modelName that is known to have previously been created (by this app)
     *   and the corresponding model ID exists and has the required number of fields
     *   then return that ID (even though it may have since been renamed)
     * If there's a model from #getModelList with modelName and required number of fields then return its ID
     * Otherwise return null
     * @param modelName the name of the model to find
     * @param numFields the minimum number of fields the model is required to have
     * @return the model ID or null if something went wrong
     */
    public Long findModelIdByName(String modelName, int numFields) {
        SharedPreferences modelsDb = mContext.getSharedPreferences(MODEL_REF_DB, Context.MODE_PRIVATE);
        long prefsModelId = modelsDb.getLong(modelName, -1L);
        // if we have a reference saved to modelName and it exists and has at least numFields then return it
        if ((prefsModelId != -1L)
                && (mApi.getModelName(prefsModelId) != null)
                && (mApi.getFieldList(prefsModelId) != null)
                && (mApi.getFieldList(prefsModelId).length >= numFields)) { // could potentially have been renamed
            return prefsModelId;
        }
        Map<Long, String> modelList = mApi.getModelList(numFields);
        if (modelList != null) {
            for (Map.Entry<Long, String> entry : modelList.entrySet()) {
                if (entry.getValue().equals(modelName)) {
                    return entry.getKey(); // first model wins
                }
            }
        }
        // model no longer exists (by name nor old id), the number of fields was reduced, or API error
        return null;
    }


    /**
     * Try to find the given deck by name, accounting for potential renaming of the deck by the user as follows:
     * If there's a deck with deckName then return it's ID
     * If there's no deck with deckName, but a ref to deckName is stored in SharedPreferences, and that deck exist in
     * AnkiDroid (i.e. it was renamed), then use that deck.Note: this deck will not be found if your app is re-installed
     * If there's no reference to deckName anywhere then return null
     * @param deckName the name of the deck to find
     * @return the did of the deck in Anki
     */
    public Long findDeckIdByName(String deckName) {
        SharedPreferences decksDb = mContext.getSharedPreferences(DECK_REF_DB, Context.MODE_PRIVATE);
        // Look for deckName in the deck list
        Long did = getDeckId(deckName);
        if (did != null) {
            // If the deck was found then return it's id
            return did;
        } else {
            // Otherwise try to check if we have a reference to a deck that was renamed and return that
            did = decksDb.getLong(deckName, -1);
            if (did != -1 && mApi.getDeckName(did) != null) {
                return did;
            } else {
                // If the deck really doesn't exist then return null
                return null;
            }
        }
    }

    /**
     * Get the ID of the deck which matches the name
     * @param deckName Exact name of deck (note: deck names are unique in Anki)
     * @return the ID of the deck that has given name, or null if no deck was found or API error
     */
    private Long getDeckId(String deckName) {
        Map<Long, String> deckList = mApi.getDeckList();
        if (deckList != null) {
            for (Map.Entry<Long, String> entry : deckList.entrySet()) {
                if (entry.getValue().equalsIgnoreCase(deckName)) {
                    return entry.getKey();
                }
            }
        }
        return null;
    }
}