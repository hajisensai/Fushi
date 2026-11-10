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

    guard let gamepad = controller.extendedGamepad else { return }
    let gamepadId = controllerIds[controller]!

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
