import 'dart:io';

import 'package:dio/dio.dart';

import 'config.dart';

/// Chiave API condivisa con il backend IIS (web.config / server.js).
const String kApiKey = 'WaDl-2026-9F2C8E4B1A7D6F03C5B9E2A48D1F7A92';

/// API key Vid Kraken (download YouTube).
const String kVidKrakenKey = '26b205b9-4493-40c6-8be1-0d170b591f6a';

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

/// Client download: Vid Kraken per YouTube (ricerca + video),
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

  static const _vkBase = 'https://vidkraken.com/api/v2';
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

  /// Formato Vid Kraken in base a audio/video e qualità richiesta.
  String _vkFormat({required bool audio, required int quality}) {
    if (audio) return 'audio-aac'; // M4A/AAC ~128kbps, compatto e riproducibile
    return switch (quality) {
      <= 360 => '360',
      <= 480 => '480',
      <= 720 => '720',
      _ => '1080',
    };
  }

  /// Estensione file in base al formato effettivamente consegnato.
  String _extForFormat(String fmt) => switch (fmt) {
        'audio-mp3' => 'mp3',
        'audio' || 'audio-aac' => 'm4a',
        _ => 'mp4',
      };

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

    // YouTube (o ricerca testuale): Vid Kraken.
    if (u.isEmpty || _isYoutubeUrl(u) || !_isSocialUrl(u)) {
      return _resolveVidKraken(query: q, url: u, audio: audio, quality: quality, cancelToken: cancelToken);
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

  /// Flusso Vid Kraken: URL YouTube → submit job → polling → downloadUrl.
  Future<MediaInfo> _resolveVidKraken({
    required String query,
    required String url,
    required bool audio,
    required int quality,
    CancelToken? cancelToken,
  }) async {
    var ytUrl = url;
    String? title;
    double? durationSec;

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

    // Submit job.
    final format = _vkFormat(audio: audio, quality: quality);
    Map<String, dynamic> job;
    try {
      final r = await dio.post<Map<String, dynamic>>(
        '$_vkBase/download',
        data: {'url': ytUrl, 'format': format},
        options: Options(
          headers: {'Authorization': 'Bearer $kVidKrakenKey'},
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 30),
        ),
        cancelToken: cancelToken,
      );
      job = r.data ?? {};
    } on DioException catch (e) {
      throw ApiException(_vkError(e));
    }
    final jobId = job['jobId']?.toString();
    if (jobId == null || jobId.isEmpty) {
      throw ApiException('Vid Kraken: risposta non valida');
    }
    title = job['title']?.toString();
    durationSec = (job['duration'] as num?)?.toDouble();

    // Polling fino a COMPLETED/FAILED (max ~4 min).
    final deadline = DateTime.now().add(const Duration(minutes: 4));
    while (DateTime.now().isBefore(deadline)) {
      if (cancelToken?.isCancelled ?? false) throw ApiException('annullato');
      await Future.delayed(const Duration(seconds: 3));
      Map<String, dynamic> st;
      try {
        final r = await dio.get<Map<String, dynamic>>(
          '$_vkBase/download/$jobId',
          options: Options(
            headers: {'Authorization': 'Bearer $kVidKrakenKey'},
            receiveTimeout: const Duration(seconds: 20),
          ),
          cancelToken: cancelToken,
        );
        st = r.data ?? {};
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) throw ApiException('annullato');
        continue; // errore di rete transitorio: riprova al prossimo giro
      }
      final status = st['status']?.toString() ?? '';
      if (status == 'COMPLETED') {
        final dl = st['downloadUrl']?.toString() ?? '';
        if (dl.isEmpty) throw ApiException('URL di download mancante');
        final actual = st['actualFormat']?.toString() ?? format;
        return MediaInfo(
          title: st['title']?.toString() ?? title ?? 'download',
          url: dl,
          ext: _extForFormat(actual),
          durationSec: durationSec ?? (st['duration'] as num?)?.toDouble(),
          fileSize: (st['fileSize'] as num?)?.toInt(),
        );
      }
      if (status == 'FAILED') {
        throw ApiException('Vid Kraken: ${st['errorCode'] ?? 'errore'}');
      }
      // IN_QUEUE / IN_PROGRESS: continua il polling
    }
    throw ApiException('Timeout: download troppo lento');
  }

  String _vkError(DioException e) {
    if (CancelToken.isCancel(e)) return 'annullato';
    final data = e.response?.data;
    if (data is Map && data['error'] != null) return data['error'].toString();
    return e.message ?? 'Errore Vid Kraken';
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
