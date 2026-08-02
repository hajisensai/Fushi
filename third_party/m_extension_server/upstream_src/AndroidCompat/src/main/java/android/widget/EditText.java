package android.widget;

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

public class EditText extends TextView {
    public EditText(android.content.Context context) { super(context); }

    public EditText(android.content.Context context, android.util.AttributeSet attrs) { super(context, attrs); }

    public EditText(android.content.Context context, android.util.AttributeSet attrs, int defStyleAttr) { super(context, attrs, defStyleAttr); }

    public EditText(android.content.Context context, android.util.AttributeSet attrs, int defStyleAttr, int defStyleRes) { super(context, attrs, defStyleAttr, defStyleRes); }

    public boolean getFreezesText() { throw new RuntimeException("Stub!"); }

    protected boolean getDefaultEditable() { throw new RuntimeException("Stub!"); }

    protected android.text.method.MovementMethod getDefaultMovementMethod() { throw new RuntimeException("Stub!"); }

    public android.text.Editable getText() { throw new RuntimeException("Stub!"); }

    public void setText(CharSequence text, android.widget.TextView.BufferType type) { throw new RuntimeException("Stub!"); }

    public void setSelection(int start, int stop) { throw new RuntimeException("Stub!"); }

    public void setSelection(int index) { throw new RuntimeException("Stub!"); }

    public void selectAll() { throw new RuntimeException("Stub!"); }

    public void extendSelection(int index) { throw new RuntimeException("Stub!"); }

    public void setEllipsize(android.text.TextUtils.TruncateAt ellipsis) { throw new RuntimeException("Stub!"); }

    public CharSequence getAccessibilityClassName() { throw new RuntimeException("Stub!"); }
}
