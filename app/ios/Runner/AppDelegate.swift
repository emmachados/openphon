import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private var storageChannel: FlutterMethodChannel?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OpenphonStorage")!
    storageChannel = FlutterMethodChannel(
      name: "app.openphon/storage", binaryMessenger: registrar.messenger())
    storageChannel?.setMethodCallHandler { call, result in
      guard call.method == "excludeLibraryFromBackup" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        let manager = FileManager.default
        for directory in [FileManager.SearchPathDirectory.applicationSupportDirectory,
                          .documentDirectory] {
          var url = try manager.url(
            for: directory, in: .userDomainMask, appropriateFor: nil, create: true)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          guard try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
              .isExcludedFromBackup == true else {
            throw NSError(domain: "OpenphonStorage", code: 1)
          }
        }
        result(true)
      } catch {
        result(FlutterError(code: "backup_exclusion_failed",
                            message: "Could not prepare private library storage.",
                            details: error.localizedDescription))
      }
    }
  }
}
