import Flutter
import UIKit
import SQLite3

/// Plugin iOS: inietta brani/playliste nella libreria Music del dispositivo
/// parlando coi servizi di sistema via usbmuxd loopback (127.0.0.1:27015)
/// usando la libreria Rust `idevice` (jkcoxson) come FFI statica.
///
/// Flusso di injectTrack:
///   1. AFC: upload del file audio in /iTunes_Control/Music/Fxx/
///   2. Download di MediaLibrary.sqlitedb (+ -wal/-shm) via AFC
///   3. INSERT righe metadata in locale con sqlite3
///   4. Upload atomico del DB modificato (file .temp + rinomina)
///   5. Kill di mediaplaybackd/MobileMusic per forzare il reload
public class MusicInjectorPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "musicdownloader/injector",
      binaryMessenger: registrar.messenger()
    )
    let instance = MusicInjectorPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let bridge = IdeviceBridge()

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      result(bridge.status())
    case "injectTrack":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "path mancante", details: nil))
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let info = try self.bridge.injectTrack(
            localPath: path,
            title: args["title"] as? String,
            artist: args["artist"] as? String,
            album: args["album"] as? String,
            trackNumber: args["trackNumber"] as? Int,
            year: args["year"] as? Int
          )
          DispatchQueue.main.async { result(info) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "INJECT_FAILED", message: "\(error)", details: nil))
          }
        }
      }
    case "createPlaylist":
      let args = call.arguments as? [String: Any] ?? [:]
      let name = args["name"] as? String ?? "Playlist"
      let tracks = args["tracks"] as? [String] ?? []
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          try self.bridge.createPlaylist(name: name, trackKeys: tracks)
          DispatchQueue.main.async { result(true) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "PLAYLIST_FAILED", message: "\(error)", details: nil))
          }
        }
      }
    case "listLibrary":
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let list = try self.bridge.listLibrary()
          DispatchQueue.main.async { result(list) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "LIST_FAILED", message: "\(error)", details: nil))
          }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
