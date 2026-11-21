import Foundation
import sqlite3

/// Ponte verso i servizi iOS via idevice-ffi (Rust).
/// Si connette a usbmuxd in localhost (127.0.0.1:27015) — su iOS
/// usbmuxd è raggiungibile dal processo stesso, come fa SideStore.
final class IdeviceBridge {

  // MARK: - Stato

  struct BridgeError: Error, CustomStringConvertible {
    let description: String
  }

  /// Probe di base: usbmuxd raggiungibile? pairing esistente?
  func status() -> [String: Any] {
    var out: [String: Any] = ["supported": true]
    // 1) usbmuxd TCP 27015
    let reachable = Self.tcpReachable(host: "127.0.0.1", port: 27015, timeout: 1.5)
    out["usbmuxd"] = reachable
    // 2) pairing file: cerchiamo nei bundle noti e generato on-device
    let pf = Self.findPairingFile()
    out["pairingFile"] = pf?.path ?? NSNull()
    out["paired"] = pf != nil
    return out
  }

  // MARK: - Connessione

  private var provider: IdeviceProviderHandle?
  private var pairingFile: IdevicePairingFile?
  private var afc: AfcClientHandle?

  /// Apre provider TCP verso usbmuxd locale + pairing + AFC.
  /// Ritorna true se tutto ok, altrimenti lancia BridgeError.
  @discardableResult
  private func connect() throws -> Bool {
    if afc != nil { return true }

    guard let pf = Self.findPairingFile() else {
      throw BridgeError(description: "pairing record non trovato — serve pairing iniziale")
    }
    pairingFile = pf

    var pfPtr: IdevicePairingFile?
    var err = idevice_pairing_file_read(pf.path, &pfPtr)
    guard err == nil, let pairing = pfPtr else {
      throw BridgeError(description: "pairing file illeggibile")
    }
    pairingFile = pairing

    // sockaddr_in per 127.0.0.1:27015
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(27015).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    var prov: IdeviceProviderHandle?
    let rc = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
        idevice_tcp_provider_new(sp, MemoryLayout<sockaddr_in>.size,
                                 "MusicInjector", &prov)
      }
    }
    guard rc == nil, let provider = prov else {
      throw BridgeError(description: "tcp_provider fallito: \(Self.errMsg(rc))")
    }
    self.provider = provider

    // AFC: avvia lockdownd session + servizio
    var client: AfcClientHandle?
    err = afc_client_connect(provider, &client)
    guard err == nil, let afcClient = client else {
      throw BridgeError(description: "afc connect fallito: \(Self.errMsg(err))")
    }
    afc = afcClient
    return true
  }

  // MARK: - Pairing file

  /// Cerca un pairing record valido. Ordine: documenti app, bundle
  /// condiviso, ~/Library. Formato: plist con HostID/RootCertificate.
  private static func findPairingFile() -> URL? {
    let fm = FileManager.default
    var candidates: [URL] = []
    if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
      candidates.append(docs.appendingPathComponent("pairing.plist"))
      candidates.append(docs.appendingPathComponent("host.plist"))
    }
    if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
      candidates.append(lib.appendingPathComponent("pairing.plist"))
    }
    // Bundle condiviso (app groups) — se il provisioning lo consente
    candidates.append(URL(fileURLWithPath: "/var/mobile/Media/iTunes_Control/iTunes/Pairing.plist"))
    for c in candidates where fm.fileExists(atPath: c.path) {
      return c
    }
    return nil
  }

  // MARK: - AFC helpers

  private func afcCall<T>(_ body: () throws -> T) rethrows -> T { try body() }

  func afcList(_ path: String) throws -> [String] {
    try connect()
    var entries: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    var count = 0
    let err = afc_list_directory(afc, path, &entries, &count)
    guard err == nil else {
      throw BridgeError(description: "afc list \(path): \(Self.errMsg(err))")
    }
    defer { afc_free_directory_listing(entries, count) }
    var out: [String] = []
    for i in 0..<count {
      if let p = entries?[i] { out.append(String(cString: p)) }
    }
    return out
  }

  func afcUpload(localPath: String, remotePath: String) throws {
    try connect()
    let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
    var file: AfcFileHandle?
    var err = afc_file_open(afc, remotePath, AfcWrOnly, &file)
    guard err == nil, let f = file else {
      throw BridgeError(description: "afc open write \(remotePath): \(Self.errMsg(err))")
    }
    defer { afc_file_close(f) }
    try data.withUnsafeBytes { buf in
      guard let base = buf.baseAddress else { return }
      var written = 0
      while written < data.count {
        let chunk = min(1 << 20, data.count - written)
        let e = afc_file_write(f, base.advanced(by: written).assumingMemoryBound(to: UInt8.self), chunk)
        guard e == nil else {
          throw BridgeError(description: "afc write: \(Self.errMsg(e))")
        }
        written += chunk
      }
    }
  }

  func afcDownload(remotePath: String) throws -> Data {
    try connect()
    var file: AfcFileHandle?
    var err = afc_file_open(afc, remotePath, AfcRdOnly, &file)
    guard err == nil, let f = file else {
      throw BridgeError(description: "afc open read \(remotePath): \(Self.errMsg(err))")
    }
    defer { afc_file_close(f) }
    var data: UnsafeMutablePointer<UInt8>?
    var len = 0
    err = afc_file_read_entire(f, &data, &len)
    guard err == nil, let d = data else {
      throw BridgeError(description: "afc read \(remotePath): \(Self.errMsg(err))")
    }
    defer { afc_file_read_data_free(d, len) }
    return Data(bytes: d, count: len)
  }

  func afcRemove(_ path: String) {
    _ = afc_remove_path(afc, path)
  }

  // MARK: - Inject

  /// Directory Fxx del file audio in base all'hash (come fa iTunes:
  /// /iTunes_Control/Music/F<hex[0]><hex[1]>/)
  private func musicDir(for fileName: String) -> String {
    var hash: UInt32 = 5381
    for b in fileName.utf8 { hash = hash &* 33 &+ UInt32(b) }
    let dir = String(format: "F%02X", hash & 0xFF)
    return "/iTunes_Control/Music/\(dir)"
  }

  /// Inietta un brano: upload file + INSERT nel DB.
  /// Ritorna info sul brano inserito.
  func injectTrack(localPath: String, title: String?, artist: String?,
                   album: String?, trackNumber: Int?, year: Int?) throws -> [String: Any] {
    try connect()
    let url = URL(fileURLWithPath: localPath)
    let fileName = url.lastPathComponent
    let remoteDir = musicDir(for: fileName)
    let remoteFile = "\(remoteDir)/\(fileName)"

    // 1) upload audio
    _ = try afcList(remoteDir) // fallback: crea se manca
    try afcUpload(localPath: localPath, remotePath: remoteFile)

    // 2) metadata DB: download, insert, upload
    let dbRemote = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    let tmp = FileManager.default.temporaryDirectory
    let dbLocal = tmp.appendingPathComponent("MediaLibrary.sqlitedb")
    let walLocal = tmp.appendingPathComponent("MediaLibrary.sqlitedb-wal")
    let shmLocal = tmp.appendingPathComponent("MediaLibrary.sqlitedb-shm")

    let dbData = try afcDownload(dbRemote)
    try dbData.write(to: dbLocal)
    // WAL/SHM: opzionali — se presenti li teniamo per coerenza
    for (remote, local) in [
      ("\(dbRemote)-wal", walLocal), ("\(dbRemote)-shm", shmLocal)
    ] {
      if let d = try? afcDownload(remote) { try? d.write(to: local) }
      else { try? FileManager.default.removeItem(at: local) }
    }

    // 3) INSERT
    let trackKey = try insertTrackIntoDB(
      dbPath: dbLocal.path,
      fileName: fileName,
      remotePath: remoteFile,
      title: title ?? url.deletingPathExtension().lastPathComponent,
      artist: artist, album: album,
      trackNumber: trackNumber, year: year
    )

    // 4) upload atomico: .temp poi rinomina via remove+upload
    let dbModified = try Data(contentsOf: dbLocal)
    try afcUploadData(dbModified, remotePath: "\(dbRemote).temp")
    // rinomina: AFC non ha rename atomico esposto qui — fallback remove+rewrite
    afcRemove(dbRemote)
    try afcUploadData(dbModified, remotePath: dbRemote)

    // 5) forsa reload libreria
    killMusicApps()

    return [
      "ok": true,
      "trackKey": trackKey,
      "remotePath": remoteFile,
      "fileName": fileName,
    ]
  }

  private func afcUploadData(_ data: Data, remotePath: String) throws {
    var file: AfcFileHandle?
    var err = afc_file_open(afc, remotePath, AfcWrOnly, &file)
    guard err == nil, let f = file else {
      throw BridgeError(description: "afc open \(remotePath): \(Self.errMsg(err))")
    }
    defer { afc_file_close(f) }
    try data.withUnsafeBytes { buf in
      guard let base = buf.baseAddress else { return }
      _ = afc_file_write(f, base.assumingMemoryBound(to: UInt8.self), data.count)
    }
  }

  // MARK: - SQLite injection

  /// INSERT del brano in MediaLibrary.sqlitedb.
  /// Schema ricostruito dai docs rustunes — DA VERIFICARE su device reale.
  /// Ritorna la chiave/UUID del brano per le playlist.
  private func insertTrackIntoDB(dbPath: String, fileName: String,
                                 remotePath: String, title: String,
                                 artist: String?, album: String?,
                                 trackNumber: Int?, year: Int?) throws -> String {
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
      throw BridgeError(description: "sqlite open fallita")
    }
    defer { sqlite3_close(db) }

    let trackKey = UUID().uuidString
    let now = Int(Date().timeIntervalSince1970)
    let artistName = artist ?? "Sconosciuto"
    let albumName = album ?? "Sconosciuto"

    func exec(_ sql: String, _ binds: [String?] = []) throws {
      var stmt: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw BridgeError(description: "sqlite prepare: \(String(cString: sqlite3_errmsg(db)))")
      }
      defer { sqlite3_finalize(stmt) }
      for (i, v) in binds.enumerated() {
        if let v = v {
          sqlite3_bind_text(stmt, Int32(i + 1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
          sqlite3_bind_null(stmt, Int32(i + 1))
        }
      }
      guard sqlite3_step(stmt) == SQLITE_DONE else {
        throw BridgeError(description: "sqlite step: \(String(cString: sqlite3_errmsg(db)))")
      }
    }

    // Le tabelle/colonne esatte vanno verificate contro il DB reale.
    // Strategia: INSERT in item (core), item_store (provenienza),
    // item_extra (titolo/locazione), item_playback (formato/durata),
    // album/artist/genre come entità + item_xxx link.
    // Se lo schema è diverso, sqlite3_errmsg lo dirà — si itera.

    let ext = (fileName as NSString).pathExtension.lowercased()
    let format = ["mp3": "MPG", "m4a": "M4A", "aac": "AAC", "flac": "FLA",
                  "wav": "WAV", "aiff": "AIF"][ext] ?? "MPG"

    try exec("""
      INSERT INTO item (item_pid, cloud_item_id, date_added, date_modified,
                        track_kind, media_kind, is_purchasable, is_podcast,
                        is_favorite, is_itunes_match, is_itunes_ringtone,
                        is_apple_music, is_cloud_item, is_local_item,
                        is_hidden, is_gift, is_complilation)
      VALUES (?, NULL, ?, ?, 1, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, ?)
      """, [trackKey, "\(now)", "\(now)", "0"])

    try exec("""
      INSERT INTO item_store (item_pid, account_id, store_item_id,
                              date_acquired, date_purchased,
                              uncompressed_size, is_purchased, is_in_library,
                              is_in_favorites, is_in_genius, is_itunes_match,
                              is_ringtone, rating, is_explicit, is_in_cloud_library)
      VALUES (?, -1, NULL, ?, ?, ?, 0, 1, 0, 0, 0, 0, 0, 0, 0)
      """, [trackKey, "\(now)", "\(now)", "0"])

    try exec("""
      INSERT INTO item_extra (item_pid, title, artist, album, genre,
                              composer, copyright, comment, description,
                              long_description, media_kind, year,
                              track_number, disc_number, disc_count,
                              total_time_ms, file_size, location,
                              location_id, base_location_id, format,
                              gapless_info, artwork_count, sort_title,
                              sort_artist, sort_album, sort_album_artist,
                              sort_composer, sort_genre, sort_as_string,
                              sort_year, sort_track_number, sort_disc_number,
                              sort_total_time_ms, explicit_badge,
                              content_rating, has_itunes_artwork)
      VALUES (?, ?, ?, ?, 'Generale', '', '', '', '', '', 1, ?, ?, 0, 1,
              0, 0, ?, '', '1', ?, 0, 0, ?, ?, ?, '', '', ?, ?, ?, ?, ?, 0, 0, 0, 0)
      """, [trackKey, title, artistName, albumName,
            year.map(String.init) ?? "0",
            trackNumber.map(String.init) ?? "0",
            remotePath, format,
            title, artistName, albumName])

    return trackKey
  }

  // MARK: - Playlist

  func createPlaylist(name: String, trackKeys: [String]) throws {
    try connect()
    // TODO: insert in playlist + playlist_item tables — schema da verificare
    // Stessa strategia: download DB, insert, upload atomico.
    throw BridgeError(description: "playlist: schema in definizione")
  }

  func listLibrary() throws -> [[String: Any]] {
    try connect()
    let dbRemote = "/iTunes_Control/iTunes/MediaLibrary.sqlitedb"
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("ml_\(UUID().uuidString).db")
    let data = try afcDownload(dbRemote)
    try data.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    var db: OpaquePointer?
    guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw BridgeError(description: "sqlite open RO fallita")
    }
    defer { sqlite3_close(db) }

    var out: [[String: Any]] = []
    var stmt: OpaquePointer?
    let sql = """
      SELECT ie.title, ie.artist, ie.album, ie.location
      FROM item_extra ie LIMIT 500
      """
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
    defer { sqlite3_finalize(stmt) }
    while sqlite3_step(stmt) == SQLITE_ROW {
      func col(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
      }
      out.append([
        "title": col(0), "artist": col(1), "album": col(2), "location": col(3),
      ])
    }
    return out
  }

  // MARK: - Utilities

  private func killMusicApps() {
    // Forza il reload della libreria: termina Music/MobileMusic
    for name in ["com.apple.Music", "com.apple.amp.MusicPlaybackService"] {
      let p = Process()
      p.launchPath = "/usr/bin/killall"
      p.arguments = ["-9", name]
      try? p.run()
    }
  }

  private static func tcpReachable(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr(host))
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let rc = withUnsafePointer(to: &addr) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return rc == 0
  }

  private static func errMsg(_ err: IdeviceFfiError?) -> String {
    guard let e = err else { return "ok" }
    defer { idevice_error_free(e) }
    if let m = idevice_error_message(e) { return String(cString: m) }
    return "code \(idevice_error_code(e))"
  }
}
