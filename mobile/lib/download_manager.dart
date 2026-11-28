import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'api_client.dart';

enum DlStatus { queued, downloading, done, error, cancelled }

class DownloadItem {
  DownloadItem({
    required this.id,
    required this.label,
    this.query,
    this.url,
    this.audio = true,
    this.quality = 0,
    this.status = DlStatus.queued,
    this.createdAt,
  });

  final String id;
  final String label;
  final String? query;
  final String? url;
  final bool audio;
  final int quality;
  DlStatus status;
  double progress = -1; // -1 = indefinito
  int received = 0;
  int total = 0;
  String? filePath;
  String? fileName;
  int bytes = 0;
  String? error;
  DateTime? createdAt;

  bool get finished => status == DlStatus.done;
  bool get failed => status == DlStatus.error || status == DlStatus.cancelled;

  /// Termine usato per cercare il brano su Apple Music: la query originale
  /// se c'è, altrimenti il nome file senza estensione.
  String get syncTerm {
    final label = this.label.trim();
    if (label.isNotEmpty && !label.startsWith('http')) return label;
    final fn = fileName ?? '';
    final dot = fn.lastIndexOf('.');
    return dot > 0 ? fn.substring(0, dot) : fn;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'query': query,
        'url': url,
        'audio': audio,
        'quality': quality,
        'status': status.name,
        'filePath': filePath,
        'fileName': fileName,
        'bytes': bytes,
        'createdAt': createdAt?.toIso8601String(),
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) {
    final item = DownloadItem(
      id: j['id'] as String,
      label: j['label'] as String? ?? '',
      query: j['query'] as String?,
      url: j['url'] as String?,
      audio: j['audio'] as bool? ?? true,
      quality: (j['quality'] as num?)?.toInt() ?? 0,
      status: DlStatus.values.firstWhere(
        (s) => s.name == j['status'],
        orElse: () => DlStatus.done,
      ),
      createdAt: j['createdAt'] != null
          ? DateTime.tryParse(j['createdAt'] as String)
          : null,
    );
    item.filePath = j['filePath'] as String?;
    item.fileName = j['fileName'] as String?;
    item.bytes = (j['bytes'] as num?)?.toInt() ?? 0;
    // Download rimasti a metà vengono segnati come errore.
    if (item.status == DlStatus.downloading || item.status == DlStatus.queued) {
      item.status = DlStatus.error;
      item.error = 'Download interrotto';
    }
    return item;
  }
}

/// Gestisce download concorrenti verso l'API e persiste la lista su disco.
class DownloadManager extends ChangeNotifier {
  DownloadManager(this.api);

  final ApiClient api;
  final List<DownloadItem> items = [];

  /// Callback invocato dopo ogni download completato (es. sync Apple Music).
  Future<void> Function(DownloadItem item)? onDone;
  final Map<String, CancelToken> _tokens = {};
  final _uuid = const Uuid();

  Directory? _filesDir;
  File? _indexFile;
  Timer? _persistTimer;

  Future<Directory> get filesDir async {
    _filesDir ??= Directory(
      '${(await getApplicationDocumentsDirectory()).path}${Platform.pathSeparator}downloads',
    );
    await _filesDir!.create(recursive: true);
    return _filesDir!;
  }

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _indexFile = File('${docs.path}${Platform.pathSeparator}downloads.json');
    try {
      final raw = await _indexFile!.readAsString();
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      items
        ..clear()
        ..addAll(list.map(DownloadItem.fromJson));
    } catch (_) {
      // Nessun indice o corrotto: si riparte da zero.
    }
    notifyListeners();
  }

  void _persist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () async {
      try {
        final f = _indexFile;
        if (f == null) return;
        await f.writeAsString(jsonEncode(items.map((e) => e.toJson()).toList()));
      } catch (_) {}
    });
  }

  Future<void> start({
    String? query,
    String? url,
    bool audio = true,
    int quality = 0,
  }) async {
    final label = (query != null && query.isNotEmpty) ? query : (url ?? 'download');
    final item = DownloadItem(
      id: _uuid.v4(),
      label: label,
      query: query,
      url: url,
      audio: audio,
      quality: quality,
      createdAt: DateTime.now(),
    );
    items.insert(0, item);
    notifyListeners();
    _persist();
    unawaited(_run(item));
  }

  Future<void> _run(DownloadItem item) async {
    api.syncBaseUrl();
    final token = CancelToken();
    _tokens[item.id] = token;
    item.status = DlStatus.downloading;
    notifyListeners();
    try {
      final dir = await filesDir;
      final tmp = File('${dir.path}${Platform.pathSeparator}${item.id}.part');

      // Fase 1+2: risolvi e scarica. Cobalt a intermittenza restituisce
      // tunnel vuoti (file da 0 byte): riprova da capo fino a 3 volte.
      const maxAttempts = 3;
      Object? lastError;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          item.status = DlStatus.downloading;
          item.progress = -1;
          notifyListeners();
          final media = await api.resolveMedia(
            query: item.query,
            url: item.url,
            audio: item.audio,
            quality: item.quality,
            cancelToken: token,
          );

          final safeTitle = media.title
              .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
              .trim();
          final fileName =
              '${safeTitle.isEmpty ? item.label : safeTitle}.${media.ext}';
          final result = await api.downloadFile(
            mediaUrl: media.url,
            fileName: fileName,
            tempPath: tmp.path,
            dirPath: dir.path,
            cancelToken: token,
            onProgress: (received, total) {
              item.received = received;
              item.total = total;
              item.progress = total > 0 ? received / total : -1;
              notifyListeners();
            },
          );
          if (result.bytes <= 0) {
            await File(result.savedPath).delete().catchError((_) => File(''));
            throw ApiException('File vuoto (0 byte)');
          }
          item.status = DlStatus.done;
          item.filePath = result.savedPath;
          item.fileName = result.fileName;
          item.bytes = result.bytes;
          item.progress = 1;
          lastError = null;
          break;
        } catch (e) {
          if (token.isCancelled ||
              (e is DioException && CancelToken.isCancel(e))) {
            rethrow;
          }
          lastError = e;
          if (attempt == maxAttempts) break;
          await Future.delayed(Duration(milliseconds: 1200 * attempt));
        }
      }
      if (lastError != null) throw lastError;
      final cb = onDone;
      if (cb != null) {
        unawaited(cb(item).catchError((_) {}));
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) || token.isCancelled) {
        item.status = DlStatus.cancelled;
      } else {
        item.status = DlStatus.error;
        item.error = e.message ?? 'Errore di rete';
      }
    } on ApiException catch (e) {
      item.status = DlStatus.error;
      item.error = e.message;
    } catch (e) {
      item.status = DlStatus.error;
      item.error = e.toString();
    } finally {
      _tokens.remove(item.id);
      await File('${(await filesDir).path}${Platform.pathSeparator}${item.id}.part')
          .delete()
          .catchError((_) => File(''));
      notifyListeners();
      _persist();
    }
  }

  Future<void> cancel(String id) async {
    _tokens[id]?.cancel('annullato');
    final item = items.where((e) => e.id == id).firstOrNull;
    if (item != null && item.status == DlStatus.queued) {
      item.status = DlStatus.cancelled;
      notifyListeners();
      _persist();
    }
  }

  Future<void> retry(DownloadItem item) async {
    item.status = DlStatus.queued;
    item.progress = -1;
    item.error = null;
    notifyListeners();
    await _run(item);
  }

  Future<void> remove(DownloadItem item) async {
    _tokens[item.id]?.cancel();
    if (item.filePath != null) {
      await File(item.filePath!).delete().catchError((_) => File(''));
    }
    items.remove(item);
    notifyListeners();
    _persist();
  }

  Future<void> clearFinished() async {
    final done = items.where((e) => e.finished).toList();
    for (final item in done) {
      await remove(item);
    }
  }
}
