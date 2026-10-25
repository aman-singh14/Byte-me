import Flutter
import NaturalLanguage
import Translation
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let translator = CaptionTranslator()
  private var translateChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Caption translation on the phone (lib/captions/caption_translator.dart).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CaptionTranslator") {
      let channel = FlutterMethodChannel(name: "omni/translate", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { [translator] call, result in translator.handle(call, result: result) }
      translateChannel = channel
    }
  }
}

/// Caption translation on the phone, with Apple's Translation framework: the text never
/// leaves the device. The language packs are downloaded by the wearer in Settings.
///
///   "translate" {text, target: "en"} -> {text, source: "es"}
///   errors: "not_installed" (details: the source language), "unsupported", "unavailable", "failed"
final class CaptionTranslator {
  private var sessions: [String: Any] = [:] // "es>en" -> TranslationSession

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "translate", let args = call.arguments as? [String: Any],
          let text = args["text"] as? String, let target = args["target"] as? String
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard #available(iOS 26.0, *) else {
      result(FlutterError(code: "unavailable", message: "Translation needs iOS 26 or later.", details: nil))
      return
    }
    Task { @MainActor in
      result(await self.translate(text, to: target))
    }
  }

  @available(iOS 26.0, *)
  @MainActor
  private func translate(_ text: String, to target: String) async -> Any {
    // Which language was spoken. Short lines ("OK.") are ambiguous: leave those as they are.
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let (detected, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.6 else {
      return ["text": text, "source": target]
    }
    let source = Locale.Language(identifier: detected.rawValue)
    let goal = Locale.Language(identifier: target)
    if source.languageCode == goal.languageCode {
      return ["text": text, "source": detected.rawValue]
    }
    switch await LanguageAvailability().status(from: source, to: goal) {
    case .installed:
      break
    case .supported:
      return FlutterError(code: "not_installed", message: "Download the languages first.", details: detected.rawValue)
    default:
      return FlutterError(code: "unsupported", message: "Can't translate that language.", details: detected.rawValue)
    }
    let key = "\(detected.rawValue)>\(target)"
    let session = sessions[key] as? TranslationSession ?? TranslationSession(installedSource: source, target: goal)
    sessions[key] = session
    do {
      let response = try await session.translate(text)
      return ["text": response.targetText, "source": detected.rawValue]
    } catch {
      return FlutterError(code: "failed", message: error.localizedDescription, details: detected.rawValue)
    }
  }
}
