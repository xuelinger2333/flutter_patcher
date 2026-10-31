import Flutter
import UIKit

/// Dart <-> iOS channel handler. Methods, arguments, error codes and boot
/// statuses match the Android plugin; see test/contract/channel.json.
///
/// iOS hosts are bytecode only. As on Android, the first rendered frame after
/// an armed attempt confirms it natively.
public class FlutterPatcherPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let bytecode = BytecodePatchManager()
  private weak var registrar: FlutterPluginRegistrar?
  private let worker = DispatchQueue(label: "flutter_patcher", qos: .userInitiated, attributes: .concurrent)
  private var eventSink: FlutterEventSink?
  /// The armed attempt whose first frame is not yet observed.
  private var pendingFrame: String?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPatcherPlugin()
    instance.registrar = registrar
    let channel = FlutterMethodChannel(name: "flutter_patcher", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    FlutterEventChannel(name: "flutter_patcher/events", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
    let center = NotificationCenter.default
    center.addObserver(instance, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(instance, selector: #selector(didBecomeActive),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  @objc private func didEnterBackground() {
    worker.async { [bytecode] in try? bytecode.foregroundChanged(false) }
  }

  @objc private func didBecomeActive() {
    worker.async { [bytecode] in try? bytecode.foregroundChanged(true) }
    // add-to-app: the engine may have run before any view controller existed.
    if let token = pendingFrame { confirmFirstFrame(token) }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emitProgress(_ phase: String, _ received: Int64, _ total: Int64) {
    DispatchQueue.main.async {
      self.eventSink?(["phase": phase, "received": received, "total": total])
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let attempt = args["attempt"] as? String
    let wire = args["wire"] as? String ?? ""
    switch call.method {
    case "bootPayload":
      bytecode.announceBootstrap()
      bytecodeCall(result) { [bytecode] in
        do {
          guard var payload = try bytecode.bootPayload(
            fingerprint: args["fingerprint"] as? String ?? "", publicKey: args["publicKeyBase64"] as? String ?? "")
          else { return nil }
          payload["envelopeBytes"] = FlutterStandardTypedData(bytes: payload["envelopeBytes"] as! Data)
          return payload
        } catch {
          BootDiagnosticStore.record(BootDiagnosticStore.unknown, message: "Bytecode boot payload rejected: \(error)")
          return nil
        }
      }
    case "saveConfig":
      bytecodeCall(result) {
        try PatcherConfig.save(maxCrashCount: args["maxCrashCount"] as? Int ?? PatcherConfig.defaultMaxCrash)
        return nil
      }
    case "markBooting":
      guard bytecode.bootstrapped else { return result(nil) }
      let foreground = UIApplication.shared.applicationState != .background
      bytecodeCall(result) { [bytecode] in
        let started = try bytecode.markBooting(attempt, foreground: foreground)
        if started, let token = attempt {
          DispatchQueue.main.async { self.confirmFirstFrame(token) }
        }
        return started
      }
    case "reportBootSuccess":
      guard bytecode.bootstrapped else { return result(nil) }
      bytecodeCall(result) { [bytecode] in
        try bytecode.success(attempt)
        return nil
      }
    case "reportDartBootError":
      guard bytecode.bootstrapped else { return result(nil) }
      // A user's init() inside a whole module owns its error hook; bind that
      // report to the currently armed attempt.
      bytecodeCall(result) { [bytecode] in
        try bytecode.error(
          attempt ?? bytecode.frameToken, message: args["message"] as? String,
          quarantine: args["quarantine"] as? Bool == true)
        return nil
      }
    case "hostStrategy":
      bytecodeCall(result) { try HostTrustConfig.load()?.strategy }
    case "checkSignedManifest":
      authenticatedCall(result) { [bytecode] in try bytecode.inspect(wire) }
    case "applySignedManifest":
      authenticatedCall(result) { [bytecode] in try bytecode.applyManifest(wire, progress: self.emitProgress) }
    case "updatePublicationTrust":
      authenticatedCall(result) { [bytecode] in
        try bytecode.updateTrust(wire)
        return ["ok": true]
      }
    case "rollback":
      worker.async { [bytecode] in
        do {
          try bytecode.rollback()
          DispatchQueue.main.async { result(nil) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "ROLLBACK_FAILED", message: "Could not persist rollback", details: nil))
          }
        }
      }
    case "currentVersion":
      bytecodeCall(result) { [bytecode] in try bytecode.currentVersion() }
    case "lastBootDiagnostic":
      result(BootDiagnosticStore.read())
    case "appVersionCode":
      result(Platform.versionCode())
    case "deviceAbi":
      result(Platform.abi)
    case "blacklist":
      bytecodeCall(result) { [bytecode] in try bytecode.blacklist() }
    case "clearBlacklist":
      bytecodeCall(result) { [bytecode] in
        try bytecode.clearBlacklist()
        return nil
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The counterpart of Android's FlutterRenderer display listener: the next
  /// rendered frame settles the armed attempt as a success.
  /// Without a view controller yet (add-to-app), it retries when the app
  /// becomes active. Flutter has one render-callback slot, so a host that sets
  /// its own afterwards replaces this one.
  private func confirmFirstFrame(_ token: String) {
    pendingFrame = token
    guard let controller = registrar?.viewController as? FlutterViewController else { return }
    controller.setFlutterViewDidRenderCallback { [weak self] in
      guard let self = self else { return }
      self.pendingFrame = nil
      self.worker.async { [bytecode = self.bytecode] in try? bytecode.success(token) }
    }
  }

  /// Network messages may contain credential-bearing URLs; none reach Dart.
  private func authenticatedCall(_ result: @escaping FlutterResult, _ operation: @escaping () throws -> Any?) {
    worker.async {
      do {
        let value = try operation()
        DispatchQueue.main.async { result(value) }
      } catch is PatcherIOError {
        DispatchQueue.main.async {
          result(FlutterError(code: "AUTH_UPDATE_IO", message: "Authenticated update I/O failed", details: nil))
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "AUTH_UPDATE_REJECTED", message: "Authenticated update rejected", details: nil))
        }
      }
    }
  }

  private func bytecodeCall(_ result: @escaping FlutterResult, _ operation: @escaping () throws -> Any?) {
    worker.async {
      do {
        let value = try operation()
        DispatchQueue.main.async { result(value) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "BYTECODE_REJECTED", message: "\(error)", details: nil))
        }
      }
    }
  }
}
