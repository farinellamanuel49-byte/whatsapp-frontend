import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Inietta brani e playlist nella libreria musicale iOS (app Music)
/// tramite i servizi di sistema esposti in locale (usbmuxd/lockdownd/AFC)
/// usando la libreria `idevice` (jkcoxson) compilata come plugin nativo.
///
/// Disponibile solo su iOS. Su altre piattaforme ogni chiamata
/// restituisce errori o valori vuoti.
class MusicInjector {
  static const _ch = MethodChannel('musicdownloader/injector');

  static bool get isSupported => Platform.isIOS;

  /// Stato della connessione col dispositivo (pairing, usbmuxd, AFC).
  /// Ritorna una mappa: {paired, connected, afcRoot, error}.
  static Future<Map<String, dynamic>> status() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('status');
      return r ?? {};
    } on MissingPluginException {
      return {'supported': false};
    } catch (e) {
      return {'supported': true, 'error': e.toString()};
    }
  }

  /// Inietta un file audio locale nella libreria Music.
  /// [localPath] percorso nel sandbox dell'app; [title], [artist], [album]
  /// sono i metadata da scrivere nel database (opzionali).
  static Future<Map<String, dynamic>> injectTrack({
    required String localPath,
    String? title,
    String? artist,
    String? album,
    int? trackNumber,
    int? year,
  }) async {
    return _ch.invokeMapMethod<String, dynamic>('injectTrack', {
      'path': localPath,
      'title': title,
      'artist': artist,
      'album': album,
      'trackNumber': trackNumber,
      'year': year,
    }).then((v) => v ?? {}) ;
  }

  /// Crea una playlist nella libreria con i brani indicati.
  /// [trackIds] sono gli id interni restituiti da injectTrack.
  static Future<bool> createPlaylist({
    required String name,
    required List<String> trackKeys,
  }) async {
    final r = await _ch.invokeMethod<bool>('createPlaylist', {
      'name': name,
      'tracks': trackKeys,
    });
    return r ?? false;
  }

  /// Elenca i brani presenti nella libreria (per verifica).
  static Future<List<Map<String, dynamic>>> listLibrary() async {
    final r = await _ch.invokeListMethod<Map<dynamic, dynamic>>('listLibrary');
    return (r ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
}
