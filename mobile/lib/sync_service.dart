import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'config.dart';

/// Client per la sync_api.py sul Raspberry Pi: upload file audio,
/// lancio di `rustunes sync` verso l'iPhone via WireGuard/Tailscale.
class SyncService extends ChangeNotifier {
  SyncService(this.settings);

  final Settings settings;

  Dio? _dio;
  Dio get dio {
    final base = settings.syncServerUrl.trim();
    _dio ??= Dio(
      BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 5),
        sendTimeout: const Duration(minutes: 10),
        headers: {'Authorization': 'Bearer ${settings.syncToken}'},
      ),
    );
    return _dio!;
  }

  bool get configured =>
      settings.syncServerUrl.trim().isNotEmpty &&
      settings.syncToken.trim().isNotEmpty;

  /// Verifica che il server Pi sia raggiungibile.
  Future<bool> health() async {
    if (!configured) return false;
    try {
      final r = await dio.get<Map<String, dynamic>>('/api/sync/health');
      return r.data?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Carica un file audio sul Pi (POST /api/sync/files/<name>).
  Future<void> uploadFile(String localPath, String remoteName) async {
    if (!configured) throw StateError('Sync server non configurato');
    final f = File(localPath);
    if (!await f.exists()) throw StateError('File non trovato');
    final length = await f.length();
    await dio.post<void>(
      '/api/sync/files/${Uri.encodeComponent(remoteName)}',
      data: f.openRead(),
      options: Options(
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': length,
        },
      ),
    );
  }

  /// Lancia `rustunes sync` sul Pi verso l'iPhone.
  Future<void> runSync() async {
    if (!configured) throw StateError('Sync server non configurato');
    await dio.post<Map<String, dynamic>>(
      '/api/sync/run',
      data: {'action': 'sync'},
    );
  }

  /// Stato dell'ultimo run di rustunes.
  Future<Map<String, dynamic>> status() async {
    if (!configured) return {'status': 'not_configured'};
    try {
      final r = await dio.get<Map<String, dynamic>>('/api/sync/status');
      return r.data ?? {};
    } catch (e) {
      return {'status': 'error', 'output': e.toString()};
    }
  }

  /// Upload + sync in un colpo solo (usato dopo ogni download).
  Future<void> uploadAndSync(String localPath, String remoteName) async {
    await uploadFile(localPath, remoteName);
    await runSync();
  }
}
