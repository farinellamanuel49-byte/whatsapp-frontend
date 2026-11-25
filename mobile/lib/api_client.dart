import 'dart:io';

import 'package:dio/dio.dart';

import 'config.dart';

/// Chiave API condivisa con il backend IIS (web.config / server.js).
const String kApiKey = 'WaDl-2026-9F2C8E4B1A7D6F03C5B9E2A48D1F7A92';

/// Cobalt self-hosted (VM AlmaLinux 82.223.13.67:9010). Download YouTube/audio/video.
/// Sovrascrivibile a build-time con --dart-define=COBALT_URL/COBALT_API_KEY.
const String kCobaltUrl = String.fromEnvironment(
    'COBALT_URL', defaultValue: 'http://82.223.13.67:9010');
const String kCobaltApiKey = String.fromEnvironment(
    'COBALT_API_KEY',
    defaultValue:
        '290f64f0a911460ea83fcd9668d2e93a0ab67030e44742998f42c69bbfac614e');

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MediaInfo {
  MediaInfo({
    required this.title,
    required this.url,
    required this.ext,
    this.thumbnail,
    this.durationSec,
    this.fileSize,
  });
  final String title;
  final String url;
  final String ext;
  final String? thumbnail;
  final double? durationSec;
  final int? fileSize;
}

class DownloadResult {
  DownloadResult({required this.savedPath, required this.fileName, required this.bytes});
  final String savedPath;
  final String fileName;
  final int bytes;
}

/// Client download: Cobalt self-hosted per YouTube (ricerca + video),
/// API IIS locale per TikTok/Instagram/Facebook.
class ApiClient {
  ApiClient(this.settings)
      : dio = Dio(
          BaseOptions(
            baseUrl: settings.baseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(minutes: 3),
            sendTimeout: const Duration(minutes: 3),
          ),
        );

  final Settings settings;
  final Dio dio;

  static const _ytSearchUrl = 'https://www.youtube.com/youtubei/v1/search';
  static const _ytApiKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

  void syncBaseUrl() => dio.options.baseUrl = settings.baseUrl;

  Options get _auth => Options(headers: {'X-API-Key': kApiKey});

  Future<bool> health() async {
    try {
      final r = await dio.get<Map<String, dynamic>>(
        '/api/download/health',
        options: _auth,
      );
      return r.statusCode == 200 && (r.data?['ok'] == true);
    } catch (_) {
      return false;
    }
  }

  bool _isSocialUrl(String u) =>
      u.contains('tiktok.com') ||
      u.contains('instagram.com') ||
      u.contains('facebook.com') ||
      u.contains('fb.watch');

  bool _isYoutubeUrl(String u) =>
      u.contains('youtube.com') || u.contains('youtu.be') || u.contains('ytsearch');

  /// Parametri richiesta Cobalt in base a audio/video e qualità.
  Map<String, dynamic> _cobaltParams({required bool audio, required int quality}) {
    if (audio) {
      return {
        'downloadMode': 'audio',
        'audioFormat': 'mp3',
        'audioBitrate': '320',
      };
    }
    final q = quality > 0 ? quality.toString() : '720';
    return {'downloadMode': 'auto', 'videoQuality': q};
  }

  /// Estensione file in base alla modalità richiesta.
  String _extForMode({required bool audio}) => audio ? 'mp3' : 'mp4';

  /// Risolve query/link in un URL diretto di download.
  Future<MediaInfo> resolveMedia({
    String? query,
    String? url,
    bool audio = true,
    int quality = 0,
    CancelToken? cancelToken,
  }) async {
    final u = url ?? '';
    final q = query ?? '';

    // YouTube (o ricerca testuale): Cobalt self-hosted.
    if (u.isEmpty || _isYoutubeUrl(u) || !_isSocialUrl(u)) {
      return _resolveCobalt(query: q, url: u, audio: audio, quality: quality, cancelToken: cancelToken);
    }
    // TikTok/Instagram/Facebook: endpoint IIS.
    return _resolveIis(query: q, url: u, audio: audio, quality: quality, cancelToken: cancelToken);
  }

  // ---------- Vid Kraken (YouTube) ----------

  /// Cerc su YouTube (InnerTube pubblico, senza login) e restituisce
  /// il primo videoId. Serve a trasformare "titolo" in URL YouTube.
  Future<String?> _youtubeSearchId(String query) async {
    try {
      final r = await dio.post<Map<String, dynamic>>(
        _ytSearchUrl,
        queryParameters: {'key': _ytApiKey},
        data: {
          'context': {
            'client': {
              'clientName': 'WEB',
              'clientVersion': '2.20241101.01.00',
              'hl': 'it',
              'gl': 'IT',
            },
          },
          'query': query,
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      return _findVideoId(r.data);
    } catch (_) {
      return null;
    }
  }

  String? _findVideoId(dynamic node) {
    if (node is Map<String, dynamic>) {
      final vid = node['videoId'];
      if (vid is String && vid.length == 11) return vid;
      for (final v in node.values) {
        final f = _findVideoId(v);
        if (f != null) return f;
      }
    } else if (node is List) {
      for (final v in node) {
        final f = _findVideoId(v);
        if (f != null) return f;
      }
    }
    return null;
  }

  /// Flusso Cobalt: URL YouTube → POST /api/json → URL file diretto.
  /// Cobalt risponde con status "tunnel"/"redirect" + url, oppure
  /// "picker" (scelta utente) o "error".
  Future<MediaInfo> _resolveCobalt({
    required String query,
    required String url,
    required bool audio,
    required int quality,
    CancelToken? cancelToken,
  }) async {
    var ytUrl = url;
    String? title;

    // Se non è un URL YouTube diretto, cerca prima il videoId.
    if (!_isYoutubeUrl(ytUrl) || ytUrl.contains('ytsearch')) {
      if (ytUrl.startsWith('ytsearch')) {
        ytUrl = ytUrl.replaceFirst(RegExp(r'^ytsearch\d*:'), '');
      }
      final term = (ytUrl.isNotEmpty && !ytUrl.startsWith('http')) ? ytUrl : query;
      final id = await _youtubeSearchId(term);
      if (id == null) throw ApiException('Nessun video YouTube trovato per "$term"');
      ytUrl = 'https://youtu.be/$id';
    }

    final params = _cobaltParams(audio: audio, quality: quality);
    final body = <String, dynamic>{'url': ytUrl, ...params};

    Map<String, dynamic> resp;
    try {
      final r = await dio.post<Map<String, dynamic>>(
        kCobaltUrl,
        data: body,
        options: Options(
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            if (kCobaltApiKey.isNotEmpty)
              'Authorization': 'Api-Key $kCobaltApiKey',
          },
          receiveTimeout: const Duration(minutes: 4),
          sendTimeout: const Duration(seconds: 30),
        ),
        cancelToken: cancelToken,
      );
      resp = r.data ?? {};
    } on DioException catch (e) {
      throw ApiException(_cobaltError(e));
    }

    final status = resp['status']?.toString() ?? '';
    if (status == 'error') {
      throw ApiException(resp['error']?.toString() ?? 'Cobalt: errore');
    }
    if (status == 'picker') {
      throw ApiException('Cobalt: video con più formati, scelta non supportata');
    }
    final dl = resp['url']?.toString() ?? '';
    if (status != 'tunnel' && status != 'redirect' || dl.isEmpty) {
      throw ApiException('Cobalt: risposta non valida (${resp.toString()})');
    }

    return MediaInfo(
      title: title ?? ytUrl,
      url: dl,
      ext: _extForMode(audio: audio),
      durationSec: (resp['duration'] as num?)?.toDouble(),
    );
  }

  String _cobaltError(DioException e) {
    if (CancelToken.isCancel(e)) return 'annullato';
    final data = e.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    return e.message ?? 'Errore Cobalt';
  }

  // ---------- IIS legacy (TikTok/Instagram/Facebook) ----------

  String _endpoint({required bool audio}) {
    // chiamato solo per URL social: la piattaforma la deduce il server
    // dal dominio, ma manteniamo la stessa logica per sicurezza.
    return audio ? 'song' : 'youtube';
  }

  Future<MediaInfo> _resolveIis({
    required String query,
    required String url,
    required bool audio,
    required int quality,
    CancelToken? cancelToken,
  }) async {
    final u = url.toLowerCase();
    final endpoint = u.contains('tiktok.com')
        ? 'tiktok'
        : u.contains('instagram.com')
            ? 'instagram'
            : u.contains('facebook.com') || u.contains('fb.watch')
                ? 'facebook'
                : _endpoint(audio: audio);

    Map<String, dynamic> data;
    try {
      final r = await dio.post<Map<String, dynamic>>(
        '/api/download/$endpoint',
        data: {'url': url, 'query': query},
        options: Options(
          headers: {'X-API-Key': kApiKey},
          sendTimeout: const Duration(minutes: 3),
          receiveTimeout: const Duration(minutes: 3),
        ),
        cancelToken: cancelToken,
      );
      data = r.data ?? {};
    } on DioException catch (e) {
      throw ApiException(_errorMessage(e));
    }

    if (data['ok'] != true) {
      throw ApiException(data['error']?.toString() ?? 'Download non riuscito');
    }

    final media = (data['media'] as List?) ?? const [];
    if (media.isEmpty) throw ApiException('Nessun file multimediale trovato');

    Map<String, dynamic> chosen = media.first as Map<String, dynamic>;
    if (!audio && media.length > 1) {
      int best = -1;
      int bestScore = -1;
      for (var i = 0; i < media.length; i++) {
        final m = media[i] as Map<String, dynamic>;
        final h = (m['height'] as num?)?.toInt() ?? 0;
        final score = quality > 0 ? -((h - quality).abs()) : h;
        if (score > bestScore) {
          bestScore = score;
          best = i;
        }
      }
      chosen = media[best] as Map<String, dynamic>;
    }

    final mUrl = chosen['url']?.toString() ?? '';
    if (mUrl.isEmpty) throw ApiException('URL del file mancante');

    return MediaInfo(
      title: data['title']?.toString() ?? 'download',
      url: mUrl,
      ext: chosen['ext']?.toString() ?? (audio ? 'mp3' : 'mp4'),
      thumbnail: data['thumbnail']?.toString(),
      durationSec: (data['duration'] as num?)?.toDouble(),
      fileSize: (chosen['fileSize'] as num?)?.toInt(),
    );
  }

  String _errorMessage(DioException e) {
    if (CancelToken.isCancel(e)) return 'annullato';
    var msg = e.message ?? 'Errore di rete';
    final data = e.response?.data;
    if (data is Map && data['error'] != null) msg = data['error'].toString();
    if (data is Map && data['message'] != null) msg = data['message'].toString();
    if (data is String && data.isNotEmpty) msg = data;
    return msg;
  }

  /// Scarica [mediaUrl] in [tempPath] e rinomina in [dirPath]/<nome>.
  /// googlevideo a volte risponde 403/410/429 al primo colpo: retry.
  Future<DownloadResult> downloadFile({
    required String mediaUrl,
    required String fileName,
    required String tempPath,
    required String dirPath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    DioException? lastError;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await dio.download(
          mediaUrl,
          tempPath,
          onReceiveProgress: onProgress,
          cancelToken: cancelToken,
        );
        lastError = null;
        break;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
        lastError = e;
        final code = e.response?.statusCode ?? 0;
        final retryable = code == 403 || code == 410 || code == 429 || code == 0;
        if (!retryable || attempt == 3) break;
        await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
      }
    }
    if (lastError != null) {
      if (CancelToken.isCancel(lastError!)) throw lastError!;
      throw ApiException(_errorMessage(lastError!));
    }

    var name = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (name.isEmpty) {
      name = 'traccia_${DateTime.now().millisecondsSinceEpoch}';
    }

    var target = File('$dirPath${Platform.pathSeparator}$name');
    var i = 1;
    while (await target.exists()) {
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      name = '${base}_$i$ext';
      target = File('$dirPath${Platform.pathSeparator}$name');
      i++;
    }

    final tmp = File(tempPath);
    await tmp.rename(target.path);
    final bytes = await target.length();
    return DownloadResult(savedPath: target.path, fileName: name, bytes: bytes);
  }
}
