import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:music_kit/music_kit.dart';

import 'config.dart';

/// Esito di una sincronizzazione download → libreria Apple Music.
class AppleSyncResult {
  AppleSyncResult({required this.added, required this.notFound, required this.failed});
  int added;
  int notFound;
  int failed;
}

/// Integrazione Apple Music (solo iOS).
///
/// - MusicKit (`music_kit`) gestisce autorizzazione e riproduzione in streaming.
/// - Le ricerche nel catalogo e nella libreria usano l'API REST
///   https://api.music.apple.com con il developer token configurato.
///
/// NOTA: Apple non consente di esportare i file audio (DRM FairPlay). I brani
/// Apple Music si riproducono in streaming; i download locali restano nella
/// sezione "Download" e sono riproducibili dal player integrato.
class AppleMusicService extends ChangeNotifier {
  AppleMusicService(this.settings)
      : _api = Dio(
          BaseOptions(
            baseUrl: 'https://api.music.apple.com',
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );

  final Settings settings;
  final Dio _api;
  final MusicKit _musicKit = MusicKit();

  bool get supported => !kIsWeb && Platform.isIOS;

  bool connected = false;
  bool busy = false;
  String? error;
  String? nowPlayingTitle;

  /// Quanti brani scaricati sono stati sincronizzati automaticamente
  /// nella libreria Apple Music in questa sessione.
  int autoSyncedCount = 0;

  MusicPlayerState? playerState;

  /// Connect: chiede l'autorizzazione Apple Music e inizializza MusicKit.
  /// Richiede `appleDeveloperToken` (e opzionalmente `appleUserToken`) in
  /// impostazioni. Il developer token è un JWT generato server-side con la
  /// chiave MusicKit dell'Apple Developer account.
  Future<void> connect() async {
    if (!supported) return;
    error = null;
    busy = true;
    notifyListeners();
    try {
      final status = await _musicKit.requestAuthorizationStatus();
      if (status is! MusicAuthorizationStatusAuthorized) {
        throw Exception('Autorizzazione Apple Music negata o non determinata');
      }
      final devToken = settings.appleDeveloperToken;
      if (devToken.isEmpty) {
        throw Exception('Developer token mancante: configuralo nelle Impostazioni');
      }
      await _musicKit.initialize(
        devToken,
        musicUserToken: settings.appleUserToken.isEmpty ? null : settings.appleUserToken,
      );
      await _musicKit.prepareToPlay();
      _musicKit.onMusicPlayerStateChanged.listen((s) {
        playerState = s;
        notifyListeners();
      });
      connected = true;
    } catch (e) {
      error = e.toString();
      connected = false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Map<String, String> get _authHeaders => {
        'Authorization': 'Bearer ${settings.appleDeveloperToken}',
        if (settings.appleUserToken.isNotEmpty)
          'Music-User-Token': settings.appleUserToken,
      };

  /// Storefront dell'utente (es. "it"), o fallback dalle impostazioni.
  Future<String> _storefront() async {
    try {
      final r = await _api.get<Map<String, dynamic>>(
        '/v1/me/storefront',
        options: Options(headers: _authHeaders),
      );
      final id = r.data?['data']?[0]?['id'];
      if (id is String && id.isNotEmpty) return id.toLowerCase();
    } catch (_) {}
    return settings.appleStorefront;
  }

  /// Cerca nel catalogo Apple Music (brani).
  Future<List<Map<String, dynamic>>> searchCatalog(String term) async {
    if (settings.appleDeveloperToken.isEmpty) {
      throw Exception('Developer token mancante');
    }
    final sf = await _storefront();
    final r = await _api.get<Map<String, dynamic>>(
      '/v1/catalog/$sf/search',
      queryParameters: {'term': term, 'types': 'songs', 'limit': 25},
      options: Options(headers: _authHeaders),
    );
    final songs = r.data?['results']?['songs']?['data'];
    if (songs is List) return songs.cast<Map<String, dynamic>>();
    return const [];
  }

  /// Brani della libreria dell'utente (richiede music-user-token).
  Future<List<Map<String, dynamic>>> librarySongs() async {
    if (settings.appleUserToken.isEmpty) {
      throw Exception('Music-User-Token mancante: serve per la libreria');
    }
    final r = await _api.get<Map<String, dynamic>>(
      '/v1/me/library/songs',
      queryParameters: {'limit': 100},
      options: Options(headers: _authHeaders),
    );
    final songs = r.data?['data'];
    if (songs is List) return songs.cast<Map<String, dynamic>>();
    return const [];
  }

  /// Aggiunge brani del catalogo alla libreria Apple Music dell'utente.
  /// Richiede Music-User-Token. Ritorna il numero di brani aggiunti.
  Future<int> addSongsToLibrary(List<String> songIds) async {
    if (songIds.isEmpty) return 0;
    if (settings.appleUserToken.isEmpty) {
      throw Exception('Music-User-Token mancante: serve per aggiungere alla libreria');
    }
    var added = 0;
    // L'endpoint accetta più id separati da virgola; si batching da 25.
    for (var i = 0; i < songIds.length; i += 25) {
      final batch = songIds.sublist(i, i + 25 > songIds.length ? songIds.length : i + 25);
      await _api.post<void>(
        '/v1/me/library',
        queryParameters: {
          'ids[songs]': batch.join(','),
        },
        options: Options(headers: _authHeaders),
      );
      added += batch.length;
    }
    return added;
  }

  /// Sincronizza i download con Apple Music: per ogni query cerca il brano
  /// nel catalogo e lo aggiunge alla libreria utente.
  Future<AppleSyncResult> syncQueriesToLibrary(List<String> queries) async {
    final result = AppleSyncResult(added: 0, notFound: 0, failed: 0);
    final ids = <String>[];

    for (final q in queries) {
      try {
        final songs = await searchCatalog(q);
        if (songs.isEmpty) {
          result.notFound++;
          continue;
        }
        final id = songs.first['id']?.toString();
        if (id != null && id.isNotEmpty) ids.add(id);
      } catch (_) {
        result.failed++;
      }
    }

    if (ids.isEmpty) return result;
    try {
      result.added = await addSongsToLibrary(ids);
    } catch (_) {
      result.failed += ids.length;
    }
    return result;
  }

  /// Sincronizzazione automatica post-download: cerca il brano nel catalogo
  /// e lo aggiunge alla libreria Apple Music. Silenziosa (usata a fine
  /// download). Ritorna true se il brano è stato aggiunto.
  Future<bool> autoSyncTrack(String term) async {
    if (!supported) return false;
    if (settings.appleDeveloperToken.isEmpty || settings.appleUserToken.isEmpty) {
      return false;
    }
    if (term.trim().isEmpty) return false;
    try {
      if (!connected) await connect();
      if (!connected) return false;
      final songs = await searchCatalog(term);
      if (songs.isEmpty) return false;
      final id = songs.first['id']?.toString();
      if (id == null || id.isEmpty) return false;
      await addSongsToLibrary([id]);
      autoSyncedCount++;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Riproduce un brano in streaming tramite MusicKit.
  /// [resource] è il JSON della canzone (catalog o library) così com'è
  /// restituito dalle API: deve contenere `id` e `type`.
  Future<void> playSong(Map<String, dynamic> resource) async {
    if (!connected) await connect();
    if (!connected) throw Exception(error ?? 'MusicKit non connesso');
    final item = Map<String, dynamic>.from(resource);
    // La libreria usa attributi con playParams: li propago se presenti.
    final attrs = item['attributes'];
    if (attrs is Map && attrs['playParams'] != null) {
      item['playParams'] = attrs['playParams'];
    }
    await _musicKit.setQueue('songs', item: item);
    nowPlayingTitle = _titleOf(item);
    notifyListeners();
    await _musicKit.play();
  }

  Future<void> pause() => _musicKit.pause();
  Future<void> resume() => _musicKit.play();
  Future<void> next() => _musicKit.skipToNextEntry();
  Future<void> previous() => _musicKit.skipToPreviousEntry();

  String _titleOf(Map<String, dynamic> item) {
    final attrs = item['attributes'];
    if (attrs is Map) {
      final t = attrs['name'] ?? attrs['songName'];
      if (t != null) return t.toString();
    }
    return 'Brano Apple Music';
  }

  String titleOf(Map<String, dynamic> item) => _titleOf(item);

  String? artistOf(Map<String, dynamic> item) {
    final attrs = item['attributes'];
    if (attrs is Map) {
      final artist = attrs['artistName'];
      if (artist != null) return artist.toString();
    }
    return null;
  }

  @override
  void dispose() {
    _musicKit.stop();
    super.dispose();
  }
}
