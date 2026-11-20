import 'dart:io';

import 'package:dio/dio.dart';

import 'config.dart';

/// Chiave API condivisa con il backend (web.config / server.js).
const String kApiKey = 'WaDl-2026-9F2C8E4B1A7D6F03C5B9E2A48D1F7A92';

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

/// Client per l'API ASP.NET su IIS (whatsappdownloaderapi).
/// Flusso: POST /api/download/{endpoint} → JSON con URL diretto del file,
/// poi download diretto dal media URL.
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

  /// Sceglie l'endpoint POST in base a query/url e tipo di contenuto.
  String _endpoint({String? query, String? url, required bool audio}) {
    final u = (url ?? '').toLowerCase();
    if (u.contains('tiktok.com')) return 'tiktok';
    if (u.contains('instagram.com')) return 'instagram';
    if (u.contains('facebook.com') || u.contains('fb.watch')) return 'facebook';
    if (audio) return 'song';
    return 'youtube';
  }

  /// Risolve query/link in un URL diretto di download.
  /// Richiede ~10-60s (validazione yt-dlp lato server).
  Future<MediaInfo> resolveMedia({
    String? query,
    String? url,
    bool audio = true,
    int quality = 0,
    CancelToken? cancelToken,
  }) async {
    final endpoint = _endpoint(query: query, url: url, audio: audio);
    // /song accetta query di ricerca; /youtube richiede 'url' — per le
    // ricerche testuali si usa la sintassi yt-dlp ytsearch1:...
    String bodyUrl = url ?? '';
    String bodyQuery = query ?? '';
    if (endpoint == 'youtube' && bodyUrl.isEmpty && bodyQuery.isNotEmpty) {
      bodyUrl = 'ytsearch1:$bodyQuery';
      bodyQuery = '';
    }
    Map<String, dynamic> data;
    try {
      final r = await dio.post<Map<String, dynamic>>(
        '/api/download/$endpoint',
        data: {'url': bodyUrl, 'query': bodyQuery},
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

    // Seleziona il media: per audio il primo; per video il più vicino alla
    // qualità richiesta (o il più alto disponibile).
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
  Future<DownloadResult> downloadFile({
    required String mediaUrl,
    required String fileName,
    required String tempPath,
    required String dirPath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    // googlevideo a volte risponde 403/410/429 al primo colpo (firma non
    // ancora propagata): si riprova qualche volta sulla stessa URL.
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

