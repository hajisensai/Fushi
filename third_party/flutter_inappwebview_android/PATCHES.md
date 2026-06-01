# Hibiki patches

This package vendors `flutter_inappwebview_android` 1.1.3 because the hosted
release does not compile with the current Android SDK setup used by Hibiki.

## compileSdk 36 WebChromeClient access fix

`InAppWebViewChromeClient.openFileChooser(...)` overloads are declared
`protected` upstream. With compileSdk 36, these legacy `WebChromeClient`
overloads are public, so Java rejects the narrower access level:

```text
attempting to assign weaker access privileges; was public
```

The three overloads are changed to `public`, preserving the existing
implementation and file-picker behavior.
