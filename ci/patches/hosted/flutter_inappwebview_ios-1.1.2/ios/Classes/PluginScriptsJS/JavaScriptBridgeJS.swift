//
//  javaScriptBridgeJS.swift
//  flutter_inappwebview
//
//  Created by Lorenzo Pichilli on 16/02/21.
//

import Foundation

let JAVASCRIPT_BRIDGE_NAME = "flutter_inappwebview"
let JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT_GROUP_NAME = "IN_APP_WEBVIEW_JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT"
// Fushi bridge lock request name; intercepted by the bridge script and InAppWebView.
let FUSHI_LOCK_BRIDGE_HANDLER_NAME = "_fushiLockBridge"

let JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT = PluginScript(
    groupName: JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT_GROUP_NAME,
    source: JAVASCRIPT_BRIDGE_JS_SOURCE,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: false,
    requiredInAllContentWorlds: true,
    messageHandlerNames: ["callHandler"])

let JAVASCRIPT_BRIDGE_JS_SOURCE = """
window.\(JAVASCRIPT_BRIDGE_NAME) = {};
\(WEB_MESSAGE_CHANNELS_VARIABLE_NAME) = {};
(function() {
    // Fushi bridge lock (docs/specs/2026-10-23-dictionary-script-sandbox.md).
    // The token lives only in this closure, never on window: sandboxed dictionary
    // iframes (opaque origin) cannot read it, so once the page has locked the
    // bridge their messages are dropped natively.
    var _fushiBridgeToken = null;
    var _fushiTokenAttached = false;
    try {
        // Every plugin script posts through window.webkit.messageHandlers[...]
        // (callHandler, console, find, web message ports/listeners, ...). Wrap
        // the shared prototype once so all of them carry the token in this frame.
        var _handlerProto = Object.getPrototypeOf(window.webkit.messageHandlers['callHandler']);
        var _originalPostMessage = _handlerProto.postMessage;
        var _functionCall = Function.prototype.call;
        var _hasOwn = Object.prototype.hasOwnProperty;
        _handlerProto.postMessage = function(body) {
            if (_fushiBridgeToken !== null && body !== null && typeof body === 'object') {
                var tokenBody = {};
                for (var key in body) {
                    if (_functionCall.call(_hasOwn, body, key)) {
                        tokenBody[key] = body[key];
                    }
                }
                tokenBody['_fushiBridgeToken'] = _fushiBridgeToken;
                body = tokenBody;
            }
            return _functionCall.call(_originalPostMessage, this, body);
        };
        _fushiTokenAttached = true;
    } catch (_) {}
    window.\(JAVASCRIPT_BRIDGE_NAME).callHandler = function() {
        var _windowId = \(WINDOW_ID_VARIABLE_JS_SOURCE);
        var _handlerName = arguments[0];
        if (_handlerName === '_fushiLockBridge' && !_fushiTokenAttached) {
            // Cannot attach the token to every call here: refuse to lock rather
            // than lock and break (or half-protect) the page.
            return Promise.resolve(false);
        }
        var _callHandlerID = setTimeout(function(){});
        var _body = {'handlerName': _handlerName, '_callHandlerID': _callHandlerID, 'args': JSON.stringify(Array.prototype.slice.call(arguments, 1)), '_windowId': _windowId};
        if (_fushiBridgeToken !== null) {
            _body['_fushiBridgeToken'] = _fushiBridgeToken;
        }
        window.webkit.messageHandlers['callHandler'].postMessage(_body);
        var _promise = new Promise(function(resolve, reject) {
            window.\(JAVASCRIPT_BRIDGE_NAME)[_callHandlerID] = {resolve: resolve, reject: reject};
        });
        if (_handlerName === '_fushiLockBridge') {
            // Native answers with the new token, or false when already locked.
            // Resolve with the dedicated value only on success.
            return _promise.then(function(token) {
                if (_fushiBridgeToken === null && typeof token === 'string' && token.length >= 32) {
                    _fushiBridgeToken = token;
                    return 'fushi-bridge-locked-v1';
                }
                return false;
            });
        }
        return _promise;
    };
})();
\(WEB_MESSAGE_LISTENER_JS_SOURCE)
\(UTIL_JS_SOURCE)
"""

let PLATFORM_READY_JS_SOURCE = "window.dispatchEvent(new Event('flutterInAppWebViewPlatformReady'));";

let JAVASCRIPT_UTIL_VAR_NAME = "window.\(JAVASCRIPT_BRIDGE_NAME)._Util"

/*
 https://github.com/github/fetch/blob/master/fetch.js
 */
let UTIL_JS_SOURCE = """
\(JAVASCRIPT_UTIL_VAR_NAME) = {
    support: {
        searchParams: 'URLSearchParams' in window,
        iterable: 'Symbol' in window && 'iterator' in Symbol,
        blob:
            'FileReader' in window &&
            'Blob' in window &&
            (function() {
              try {
                new Blob();
                return true;
              } catch (e) {
                return false;
              }
            })(),
        formData: 'FormData' in window,
        arrayBuffer: 'ArrayBuffer' in window
    },
    isDataView: function(obj) {
        return obj && DataView.prototype.isPrototypeOf(obj);
    },
    fileReaderReady: function(reader) {
          return new Promise(function(resolve, reject) {
                reader.onload = function() {
                    resolve(reader.result);
                };
                reader.onerror = function() {
                    reject(reader.error);
                };
          });
    },
    readBlobAsArrayBuffer: function(blob) {
        var reader = new FileReader();
        var promise = \(JAVASCRIPT_UTIL_VAR_NAME).fileReaderReady(reader);
        reader.readAsArrayBuffer(blob);
        return promise;
    },
    convertBodyToArrayBuffer: function(body) {
        var viewClasses = [
            '[object Int8Array]',
            '[object Uint8Array]',
            '[object Uint8ClampedArray]',
            '[object Int16Array]',
            '[object Uint16Array]',
            '[object Int32Array]',
            '[object Uint32Array]',
            '[object Float32Array]',
            '[object Float64Array]'
        ];
        var isArrayBufferView = null;
        if (\(JAVASCRIPT_UTIL_VAR_NAME).support.arrayBuffer) {
            isArrayBufferView =
                ArrayBuffer.isView ||
                function(obj) {
                    return obj && viewClasses.indexOf(Object.prototype.toString.call(obj)) > -1;
                };
        }

        var bodyUsed = false;

        this._bodyInit = body;
        if (!body) {
            this._bodyText = '';
        } else if (typeof body === 'string') {
            this._bodyText = body;
        } else if (\(JAVASCRIPT_UTIL_VAR_NAME).support.blob && Blob.prototype.isPrototypeOf(body)) {
            this._bodyBlob = body;
        } else if (\(JAVASCRIPT_UTIL_VAR_NAME).support.formData && FormData.prototype.isPrototypeOf(body)) {
            this._bodyFormData = body;
        } else if (\(JAVASCRIPT_UTIL_VAR_NAME).support.searchParams && URLSearchParams.prototype.isPrototypeOf(body)) {
            this._bodyText = body.toString();
        } else if (\(JAVASCRIPT_UTIL_VAR_NAME).support.arrayBuffer && \(JAVASCRIPT_UTIL_VAR_NAME).support.blob && \(JAVASCRIPT_UTIL_VAR_NAME).isDataView(body)) {
            this._bodyArrayBuffer = bufferClone(body.buffer);
            this._bodyInit = new Blob([this._bodyArrayBuffer]);
        } else if (\(JAVASCRIPT_UTIL_VAR_NAME).support.arrayBuffer && (ArrayBuffer.prototype.isPrototypeOf(body) || isArrayBufferView(body))) {
            this._bodyArrayBuffer = bufferClone(body);
        } else {
            this._bodyText = body = Object.prototype.toString.call(body);
        }

        this.blob = function () {
            if (bodyUsed) {
                return Promise.reject(new TypeError('Already read'));
            }
            bodyUsed = true;
            if (this._bodyBlob) {
                return Promise.resolve(this._bodyBlob);
            } else if (this._bodyArrayBuffer) {
                return Promise.resolve(new Blob([this._bodyArrayBuffer]));
            } else if (this._bodyFormData) {
                throw new Error('could not read FormData body as blob');
            } else {
                return Promise.resolve(new Blob([this._bodyText]));
            }
        };

        if (this._bodyArrayBuffer) {
            if (bodyUsed) {
                return Promise.reject(new TypeError('Already read'));
            }
            bodyUsed = true;
            if (ArrayBuffer.isView(this._bodyArrayBuffer)) {
                return Promise.resolve(
                  this._bodyArrayBuffer.buffer.slice(
                    this._bodyArrayBuffer.byteOffset,
                    this._bodyArrayBuffer.byteOffset + this._bodyArrayBuffer.byteLength
                  )
                );
            } else {
                return Promise.resolve(this._bodyArrayBuffer);
            }
        }
        return this.blob().then(\(JAVASCRIPT_UTIL_VAR_NAME).readBlobAsArrayBuffer);
    },
    isString: function(variable) {
        return typeof variable === 'string' || variable instanceof String;
    },
    convertBodyRequest: function(body) {
        if (body == null) {
            return new Promise((resolve, reject) => resolve(null));
        }
        if (\(JAVASCRIPT_UTIL_VAR_NAME).isString(body) || (\(JAVASCRIPT_UTIL_VAR_NAME).support.searchParams && body instanceof URLSearchParams)) {
            return new Promise((resolve, reject) => resolve(body.toString()));
        }
        if (window.Response != null) {
            return new Response(body).arrayBuffer().then(function(arrayBuffer) {
                return Array.from(new Uint8Array(arrayBuffer));
            });
        }
        return \(JAVASCRIPT_UTIL_VAR_NAME).convertBodyToArrayBuffer(body).then(function(arrayBuffer) {
            return Array.from(new Uint8Array(arrayBuffer));
        });
    },
    arrayBufferToString: function(arrayBuffer) {
        var uint8Array = new Uint8Array(arrayBuffer);
        return uint8Array.reduce(function(acc, i) { return acc += String.fromCharCode.apply(null, [i]); }, '');
    },
    isBodyFormData: function(bodyString) {
        return bodyString.indexOf('------WebKitFormBoundary') >= 0;
    },
    getFormDataContentType: function(bodyString) {
        var boundary = bodyString.substr(2, 40);
        return 'multipart/form-data; boundary=' + boundary;
    },
    convertHeadersToJson: function(headers) {
        var headersObj = {};
        for (var header of headers.keys()) {
          var value = headers.get(header);
          headersObj[header] = value;
        }
        return headersObj;
    },
    convertJsonToHeaders: function(headersJson) {
        return new Headers(headersJson);
    },
    convertCredentialsToJson: function(credentials) {
        var credentialsObj = {};
        if (window.FederatedCredential != null && credentials instanceof FederatedCredential) {
          credentialsObj.type = credentials.type;
          credentialsObj.id = credentials.id;
          credentialsObj.name = credentials.name;
          credentialsObj.protocol = credentials.protocol;
          credentialsObj.provider = credentials.provider;
          credentialsObj.iconURL = credentials.iconURL;
        } else if (window.PasswordCredential != null && credentials instanceof PasswordCredential) {
          credentialsObj.type = credentials.type;
          credentialsObj.id = credentials.id;
          credentialsObj.name = credentials.name;
          credentialsObj.password = credentials.password;
          credentialsObj.iconURL = credentials.iconURL;
        } else {
          credentialsObj.type = 'default';
          credentialsObj.value = credentials;
        }
        return credentialsObj;
    },
    convertJsonToCredential: function(credentialsJson) {
        var credentials;
        if (window.FederatedCredential != null && credentialsJson.type === 'federated') {
          credentials = new FederatedCredential({
            id: credentialsJson.id,
            name: credentialsJson.name,
            protocol: credentialsJson.protocol,
            provider: credentialsJson.provider,
            iconURL: credentialsJson.iconURL
          });
        } else if (window.PasswordCredential != null && credentialsJson.type === 'password') {
          credentials = new PasswordCredential({
            id: credentialsJson.id,
            name: credentialsJson.name,
            password: credentialsJson.password,
            iconURL: credentialsJson.iconURL
          });
        } else {
          credentials = credentialsJson.value == null ? undefined : credentialsJson.value;
        }
        return credentials;
    }
};
"""
