import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sincronizzazione con YouTube Music via InnerTube (API interna).
///
/// Richiede il cookie SAPISID dell'account Google: si recupera dal
/// browser collegati a music.youtube.com (DevTools → Application →
/// Cookies → SAPISID). Funziona solo su Android.
///
/// ATTENZIONE: InnerTube non è un'API pubblica — può cambiare o
/// fallire senza preavviso ed è contro i ToS di YouTube.
class YouTubeMusicService extends ChangeNotifier {
  YouTubeMusicService();

  static const _kSapisid = 'ytmusic_sapisid';
  static const _origin = 'https://music.youtube.com';
  static const _apiKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  static const _clientVersion = '1.20241201.01.00';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'Content-Type': 'application/json'},
  ));

  String sapisid = '';
  int syncedCount = 0;
  int failedCount = 0;

  bool get configured => sapisid.trim().isNotEmpty;
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    sapisid = p.getString(_kSapisid) ?? '';
    notifyListeners();
  }

  Future<void> saveSapisid(String value) async {
    sapisid = value.trim();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kSapisid, sapisid);
    notifyListeners();
  }

  /// Header SAPISIDHASH: firma temporale del cookie (algoritmo ufficiale).
  String _authHeader() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final input = '$ts $sapisid $_origin';
    final hash = sha1.convert(utf8.encode(input)).toString();
    return 'SAPISIDHASH ${ts}_$hash';
  }

  Map<String, dynamic> _context() => {
        'client': {
          'clientName': 'WEB_REMIX',
          'clientVersion': _clientVersion,
          'hl': 'it',
          'gl': 'IT',
        },
      };

  /// Cerca un brano nel catalogo YouTube Music e ritorna il videoId.
  Future<String?> searchSongId(String query) async {
    if (!configured) return null;
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_origin/youtubei/v1/search?key=$_apiKey',
        data: {
          'context': _context(),
          'query': query,
        },
        options: Options(headers: {
          'Authorization': _authHeader(),
          'Origin': _origin,
          'Referer': '$_origin/',
          'X-Origin': _origin,
          'Cookie': 'SAPISID=$sapisid',
        }),
      );
      final id = _findFirstVideoId(res.data);
      return id;
    } catch (_) {
      return null;
    }
  }

  /// Aggiunge un videoId ai "Brani piaciuti" (Liked Music) di YT Music.
  Future<bool> likeSong(String videoId) async {
    if (!configured) return false;
    try {
      await _dio.post<Map<String, dynamic>>(
        '$_origin/youtubei/v1/like/like?key=$_apiKey',
        data: {
          'context': _context(),
          'target': {'videoId': videoId},
          'likeStatus': 'LIKE',
        },
        options: Options(headers: {
          'Authorization': _authHeader(),
          'Origin': _origin,
          'Referer': '$_origin/',
          'X-Origin': _origin,
          'Cookie': 'SAPISID=$sapisid',
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Flusso completo: query → videoId → like. Ritorna true se riuscito.
  Future<bool> syncQuery(String query) async {
    if (!configured || query.trim().isEmpty) return false;
    final id = await searchSongId(query.trim());
    if (id == null) {
      failedCount++;
      notifyListeners();
      return false;
    }
    final ok = await likeSong(id);
    if (ok) {
      syncedCount++;
    } else {
      failedCount++;
    }
    notifyListeners();
    return ok;
  }

  /// Cerca il primo videoId nel JSON annidato della risposta search.
  /// I risultati canzone hanno playlistItemData.videoId.
  String? _findFirstVideoId(dynamic node) {
    if (node is Map<String, dynamic>) {
      // musicResponsiveListItemRenderer → playlistItemData
      final playlistItem = node['playlistItemData'];
      if (playlistItem is Map<String, dynamic>) {
        final vid = playlistItem['videoId'];
        if (vid is String && vid.isNotEmpty) return vid;
      }
      for (final v in node.values) {
        final found = _findFirstVideoId(v);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final v in node) {
        final found = _findFirstVideoId(v);
        if (found != null) return found;
      }
    }
    return null;
  }
}
