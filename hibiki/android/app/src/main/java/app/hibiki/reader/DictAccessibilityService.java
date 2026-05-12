package app.hibiki.reader;

import android.accessibilityservice.AccessibilityService;
import android.util.Log;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;

public class DictAccessibilityService extends AccessibilityService {

    private static final String TAG = "DictAccessibility";

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event.getEventType() != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED) return;

        FloatingDictService svc = FloatingDictService.getInstance();
        if (svc == null) return;

        AccessibilityNodeInfo node = event.getSource();
        if (node == null) return;

        try {
            CharSequence text = node.getText();
            int start = node.getTextSelectionStart();
            int end = node.getTextSelectionEnd();

            if (text != null && start >= 0 && end > start && end <= text.length()) {
                String selected = text.subSequence(start, end).toString().trim();
                if (!selected.isEmpty()) {
                    Log.d(TAG, "selected: " + selected);
                    svc.onTextSelected(selected);
                }
            }
        } finally {
            node.recycle();
        }
    }

    @Override
    public void onInterrupt() {
    }
}
