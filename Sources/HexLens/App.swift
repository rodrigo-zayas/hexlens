import AppKit
import HexLensUI
import SwiftUI

@main
struct HexLensApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("HexLens") {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 1100, minHeight: 680)
        .onAppear {
          if let path = ProcessInfo.processInfo.environment["HEXLENS_CAPTURE"] { SelfCapture.start(model: model, to: path) }
          // `HexLens -repo /ruta [-pr N]`. AppKit vuelca los `-clave valor` en UserDefaults; un
          // argumento suelto lo trataría como documento y SwiftUI no abriría la ventana.
          if let path = UserDefaults.standard.string(forKey: "repo") {
            model.openRepository(URL(fileURLWithPath: path))
            let pr = UserDefaults.standard.integer(forKey: "pr")
            if pr > 0 {
              model.showPRPicker = false
              model.openPR(number: pr, base: UserDefaults.standard.string(forKey: "base"))
            }
          }
        }
    }
    .defaultSize(width: 1680, height: 1020)
    .commands { ReviewCommands(model: model) }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Ejecutable de SPM sin bundle: hay que pedir ser app de primer plano.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Depuración: con `HEXLENS_CAPTURE=/ruta.png`, la app se captura a sí misma cuando termina de cargar.
@MainActor
enum SelfCapture {
  static func start(model: AppModel, to path: String) {
    Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
      MainActor.assumeIsolated {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.height > 200 }
        guard model.session != nil, model.busy == nil, let window = windows.first, let view = window.contentView?.superview else { return }
        timer.invalidate()
        let env = ProcessInfo.processInfo.environment
        for text in (env["HEXLENS_CAPTURE_FOLLOW"] ?? "").split(separator: ",") {
          FileHandle.standardError.write(Data("sigue \(text): \(model.followLink(text: String(text))) → \(model.location?.path ?? "-"):\(model.location?.line ?? 0)\n".utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
          guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
          view.cacheDisplay(in: view.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
          FileHandle.standardError.write(Data("capturada \(path)\n".utf8))
        }
      }
    }
  }
}
