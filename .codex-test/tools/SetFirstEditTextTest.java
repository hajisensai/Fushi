import android.os.Bundle;

import com.android.uiautomator.core.UiDevice;
import com.android.uiautomator.core.UiObject;
import com.android.uiautomator.core.UiSelector;
import com.android.uiautomator.testrunner.UiAutomatorTestCase;

public class SetFirstEditTextTest extends UiAutomatorTestCase {
    public void testSetText() throws Exception {
        Bundle params = getParams();
        String text = params.getString("text");
        if (text == null) {
            text = "";
        }
        boolean enter = Boolean.parseBoolean(params.getString("enter"));

        UiDevice device = getUiDevice();
        UiObject editText = new UiObject(
            new UiSelector().className("android.widget.EditText").instance(0)
        );
        if (!editText.exists()) {
            throw new AssertionError("No EditText found");
        }

        editText.click();
        editText.setText(text);
        if (enter) {
            device.pressEnter();
        }
    }
}
