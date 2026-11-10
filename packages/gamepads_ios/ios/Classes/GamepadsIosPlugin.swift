import Flutter
import UIKit
import GameController

public class GamepadsIosPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel!
  private var controllerIds = [GCController: Int]()
  private var nextControllerId = 1

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = GamepadsIosPlugin()
    instance.channel = FlutterMethodChannel(name: "xyz.luan/gamepads", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: instance.channel)

    NotificationCenter.default.addObserver(
      instance,
      selector: #selector(instance.controllerConnected),
      name: .GCControllerDidConnect,
      object: nil
    )

    NotificationCenter.default.addObserver(
      instance,
      selector: #selector(instance.controllerDisconnected),
      name: .GCControllerDidDisconnect,
      object: nil
    )

    for controller in GCController.controllers() {
      instance.setupController(controller)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "listGamepads" {
      let gamepads = controllerIds.compactMap { (controller, id) -> [String: Any]? in
        guard let vendorName = controller.vendorName else { return nil }
        return [
          "id": String(id),
          "name": vendorName
        ]
      }
      result(gamepads)
    } else {
      result(FlutterMethodNotImplemented)
    }
  }

  @objc private func controllerConnected(notification: Notification) {
    if let controller = notification.object as? GCController {
      setupController(controller)
    }
  }

  @objc private func controllerDisconnected(notification: Notification) {
    if let controller = notification.object as? GCController {
      controllerIds.removeValue(forKey: controller)
      // Optional: send disconnection event
    }
  }

  private func setupController(_ controller: GCController) {
    if controllerIds[controller] == nil {
      controllerIds[controller] = nextControllerId
      nextControllerId += 1
    }

    let gamepadId = controllerIds[controller]!

    if let gamepad = controller.extendedGamepad {
      setupExtendedGamepad(gamepad, gamepadId: gamepadId)
    } else if #available(iOS 14.0, *) {
      // Fushi fork (feedback 2F3oApV21V / GitHub #3122): upstream returned here
      // for every controller without the extended profile, so a single
      // Nintendo Switch Joy-Con (iOS 16+ exposes it with NO extendedGamepad)
      // never reached Dart at all. Every GCController has a
      // physicalInputProfile; wire its standard elements under the SAME raw
      // keys the extended path emits, so the gamepads IosMapping normalizes
      // them unchanged (SL/SR -> shoulders, stick -> d-pad/left stick, ...).
      setupPhysicalInputProfile(controller.physicalInputProfile, gamepadId: gamepadId)
    }
  }

  private func setupExtendedGamepad(_ gamepad: GCExtendedGamepad, gamepadId: Int) {
    // D-Pad
    gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
      self?.sendEvent(gamepadId: gamepadId, key: "dpad - xAxis", value: xValue, isAnalog: true)
      self?.sendEvent(gamepadId: gamepadId, key: "dpad - yAxis", value: yValue, isAnalog: true)
    }

    // Left stick
    gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
      self?.sendEvent(gamepadId: gamepadId, key: "leftStick - xAxis", value: xValue, isAnalog: true)
      self?.sendEvent(gamepadId: gamepadId, key: "leftStick - yAxis", value: yValue, isAnalog: true)
    }

    // Right stick
    gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
      self?.sendEvent(gamepadId: gamepadId, key: "rightStick - xAxis", value: xValue, isAnalog: true)
      self?.sendEvent(gamepadId: gamepadId, key: "rightStick - yAxis", value: yValue, isAnalog: true)
    }

    // Triggers (ANALOG)
    gamepad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
      self?.sendEvent(gamepadId: gamepadId, key: "leftTrigger", value: value, isAnalog: true)
    }

    gamepad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
      self?.sendEvent(gamepadId: gamepadId, key: "rightTrigger", value: value, isAnalog: true)
    }

    // Digital buttons
    var buttons: [(GCControllerButtonInput?, String)] = [
      (gamepad.buttonA, "buttonA"),
      (gamepad.buttonB, "buttonB"),
      (gamepad.buttonX, "buttonX"),
      (gamepad.buttonY, "buttonY"),
      (gamepad.leftShoulder, "leftShoulder"),
      (gamepad.rightShoulder, "rightShoulder"),
      (gamepad.leftThumbstickButton, "leftThumbstickButton"),
      (gamepad.rightThumbstickButton, "rightThumbstickButton")
    ]

    if #available(iOS 14.0, *) {
      buttons.append((gamepad.buttonMenu, "buttonMenu"))
      buttons.append((gamepad.buttonOptions, "buttonOptions"))
      buttons.append((gamepad.buttonHome, "buttonHome"))
    }

    for (button, name) in buttons {
      button?.valueChangedHandler = { [weak self] _, _, pressed in
        self?.sendEvent(gamepadId: gamepadId, key: name, value: pressed ? 1.0 : 0.0, isAnalog: false)
      }
    }
  }

  /// Standard d-pad / stick elements of a [GCPhysicalInputProfile] -> the raw
  /// key prefix the extended path uses ("<prefix> - xAxis" / "- yAxis").
  /// Elements with any other name (vendor-specific touchpads, ...) are ignored.
  @available(iOS 14.0, *)
  static func profileDpadKey(for element: String) -> String? {
    switch element {
    case GCInputDirectionPad: return "dpad"
    case GCInputLeftThumbstick: return "leftStick"
    case GCInputRightThumbstick: return "rightStick"
    default: return nil
    }
  }

  /// Standard button elements of a [GCPhysicalInputProfile] -> the raw key the
  /// extended path uses, and whether the extended path reports it as analog
  /// (triggers) or digital. The per-direction buttons a d-pad also lists under
  /// `buttons` ("Direction Pad Up", ...) are deliberately absent: the d-pad is
  /// already reported once through [profileDpadKey].
  @available(iOS 14.0, *)
  static func profileButtonKey(for element: String) -> (key: String, isAnalog: Bool)? {
    switch element {
    case GCInputButtonA: return ("buttonA", false)
    case GCInputButtonB: return ("buttonB", false)
    case GCInputButtonX: return ("buttonX", false)
    case GCInputButtonY: return ("buttonY", false)
    case GCInputLeftShoulder: return ("leftShoulder", false)
    case GCInputRightShoulder: return ("rightShoulder", false)
    case GCInputLeftTrigger: return ("leftTrigger", true)
    case GCInputRightTrigger: return ("rightTrigger", true)
    case GCInputLeftThumbstickButton: return ("leftThumbstickButton", false)
    case GCInputRightThumbstickButton: return ("rightThumbstickButton", false)
    case GCInputButtonMenu: return ("buttonMenu", false)
    case GCInputButtonOptions: return ("buttonOptions", false)
    case GCInputButtonHome: return ("buttonHome", false)
    default: return nil
    }
  }

  @available(iOS 14.0, *)
  private func setupPhysicalInputProfile(_ profile: GCPhysicalInputProfile, gamepadId: Int) {
    for (name, dpad) in profile.dpads {
      guard let prefix = GamepadsIosPlugin.profileDpadKey(for: name) else { continue }
      dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
        self?.sendEvent(gamepadId: gamepadId, key: "\(prefix) - xAxis", value: xValue, isAnalog: true)
        self?.sendEvent(gamepadId: gamepadId, key: "\(prefix) - yAxis", value: yValue, isAnalog: true)
      }
    }

    for (name, button) in profile.buttons {
      guard let mapped = GamepadsIosPlugin.profileButtonKey(for: name) else { continue }
      let key = mapped.key
      if mapped.isAnalog {
        button.valueChangedHandler = { [weak self] _, value, _ in
          self?.sendEvent(gamepadId: gamepadId, key: key, value: value, isAnalog: true)
        }
      } else {
        button.valueChangedHandler = { [weak self] _, _, pressed in
          self?.sendEvent(gamepadId: gamepadId, key: key, value: pressed ? 1.0 : 0.0, isAnalog: false)
        }
      }
    }
  }

  private func sendEvent(gamepadId: Int, key: String, value: Float, isAnalog: Bool) {
    channel.invokeMethod("onGamepadEvent", arguments: [
      "type": isAnalog ? "analog" : "button",
      "gamepadId": String(gamepadId),
      "key": key,
      "value": value,
      "time": Int(Date().timeIntervalSince1970 * 1000)
    ])
  }
}
