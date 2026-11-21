import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../apple_music_service.dart';
import '../download_manager.dart';
import '../music_injector.dart';
import '../player_service.dart';
import '../playlist_service.dart';
import '../sync_service.dart';
import '../youtube_music_service.dart';

/// Scheda "Download": lista dei file scaricati con progresso e riproduzione.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  bool _syncing = false;

  /// Sincronizza manualmente (ri-sync) tutti i brani audio completati.
  Future<void> _syncWithAppleMusic() async {
    final apple = context.read<AppleMusicService>();
    final dm = context.read<DownloadManager>();
    final done = dm.items.where((e) => e.finished && e.audio).toList();
    if (done.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun brano audio scaricato da sincronizzare.')),
      );
      return;
    }
    final queries = done.map((e) => e.syncTerm).where((q) => q.isNotEmpty).toSet().toList();
    setState(() => _syncing = true);
    try {
      final res = await apple.syncQueriesToLibrary(queries);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Apple Music: ${res.added} brani aggiunti alla libreria'
            '${res.notFound > 0 ? ' · ${res.notFound} non trovati' : ''}'
            '${res.failed > 0 ? ' · ${res.failed} errori' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sincronizzazione fallita: $e')),
      );
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  bool _syncingYT = false;

  /// Sincronizza manualmente (ri-sync) tutti i brani audio su YouTube Music.
  Future<void> _syncWithYouTubeMusic() async {
    final yt = context.read<YouTubeMusicService>();
    final dm = context.read<DownloadManager>();
    if (!yt.configured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configura prima il cookie SAPISID nelle Impostazioni.'),
        ),
      );
      return;
    }
    final done = dm.items.where((e) => e.finished && e.audio).toList();
    if (done.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun brano audio scaricato da sincronizzare.')),
      );
      return;
    }
    final queries = done.map((e) => e.syncTerm).where((q) => q.isNotEmpty).toSet().toList();
    setState(() => _syncingYT = true);
    var ok = 0;
    for (final q in queries) {
      if (await yt.syncQuery(q)) ok++;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'YouTube Music: $ok brani aggiunti ai Mi piace'
          '${queries.length - ok > 0 ? ' · ${queries.length - ok} non trovati' : ''}',
        ),
      ),
    );
    setState(() => _syncingYT = false);
  }

  bool _syncingPi = false;

  /// Carica tutti i brani audio completati sul Pi e lancia rustunes.
  Future<void> _syncWithPi() async {
    final sync = context.read<SyncService>();
    final dm = context.read<DownloadManager>();
    if (!sync.configured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configura il server sync nelle Impostazioni.'),
        ),
      );
      return;
    }
    final done = dm.items
        .where((e) => e.finished && e.audio && e.filePath != null)
        .toList();
    if (done.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun brano audio scaricato.')),
      );
      return;
    }
    setState(() => _syncingPi = true);
    try {
      var uploaded = 0;
      for (final item in done) {
        try {
          await sync.uploadFile(item.filePath!, item.fileName ?? item.id);
          uploaded++;
        } catch (_) {}
      }
      await sync.runSync();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Caricati $uploaded brani sul Pi — sync iPhone avviata. '
            'Controlla lo stato tra poco.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sync Pi fallita: $e')),
      );
    } finally {
      if (mounted) setState(() => _syncingPi = false);
    }
  }

  bool _injecting = false;

  /// Inietta tutti i brani audio completati nella libreria Music iOS.
  Future<void> _injectAll() async {
    final dm = context.read<DownloadManager>();
    final done = dm.items
        .where((e) => e.finished && e.audio && e.filePath != null)
        .toList();
    if (done.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun brano audio scaricato.')),
      );
      return;
    }
    setState(() => _injecting = true);
    var ok = 0;
    String? lastError;
    for (final item in done) {
      try {
        final r = await MusicInjector.injectTrack(
          localPath: item.filePath!,
          title: item.fileName,
          artist: item.label,
        );
        if (r['ok'] == true) ok++;
      } catch (e) {
        lastError = e.toString();
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Iniettati $ok brani in Music'
          '${done.length - ok > 0 ? ' · ${done.length - ok} errori' : ''}'
          '${lastError != null ? ' — $lastError' : ''}',
        ),
      ),
    );
    setState(() => _injecting = false);
  }

  Future<void> _playAll(List<DownloadItem> done) async {
    final player = context.read<PlayerService>();
    final tracks = done
        .where((e) => e.filePath != null)
        .map((e) => LocalTrack(
              id: e.id,
              title: e.fileName ?? e.label,
              filePath: e.filePath!,
            ))
        .toList();
    await player.playQueue(tracks);
  }

  @override
  Widget build(BuildContext context) {
    final dm = context.watch<DownloadManager>();
    final done = dm.items.where((e) => e.finished && e.filePath != null).toList();
    final apple = context.watch<AppleMusicService>();
    final ytMusic = context.watch<YouTubeMusicService>();
    final sync = context.watch<SyncService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Download'),
        actions: [
          if (ytMusic.supported && ytMusic.syncedCount > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${ytMusic.syncedCount} su YT Music',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF4FE3C0)),
                ),
              ),
            ),
          if (apple.supported && apple.autoSyncedCount > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${apple.autoSyncedCount} su Apple Music',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF4FE3C0)),
                ),
              ),
            ),
          if (ytMusic.supported && dm.items.any((e) => e.finished && e.audio))
            IconButton(
              tooltip: 'Sincronizza con YouTube Music',
              icon: _syncingYT
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.music_note),
              onPressed: _syncingYT ? null : _syncWithYouTubeMusic,
            ),
          if (apple.supported && dm.items.any((e) => e.finished && e.audio))
            IconButton(
              tooltip: 'Sincronizza con Apple Music',
              icon: _syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync),
              onPressed: _syncing ? null : _syncWithAppleMusic,
            ),
          if (Platform.isIOS && dm.items.any((e) => e.finished && e.audio))
            IconButton(
              tooltip: 'Inietta nella libreria Music',
              icon: _injecting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.library_add),
              onPressed: _injecting ? null : _injectAll,
            ),
          if (sync.configured && dm.items.any((e) => e.finished && e.audio))
            IconButton(
              tooltip: 'Sincronizza con iPhone (server Pi)',
              icon: _syncingPi
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.phone_iphone),
              onPressed: _syncingPi ? null : _syncWithPi,
            ),
          if (done.isNotEmpty)
            IconButton(
              tooltip: 'Riproduci tutto',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => _playAll(done),
            ),
          if (dm.items.any((e) => e.finished))
            IconButton(
              tooltip: 'Svuota completati',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: dm.clearFinished,
            ),
        ],
      ),
      body: dm.items.isEmpty
          ? const Center(
              child: Text(
                'Nessun download.\nCerca un brano nella scheda Cerca.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: dm.items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _DownloadTile(item: dm.items[i]),
            ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.item});
  final DownloadItem item;

  String _fmtBytes(int b) {
    if (b <= 0) return '';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Mostra il selettore playlist e aggiunge il brano alla scelta.
  Future<void> _addToPlaylist(BuildContext context, DownloadItem item) async {
    final svc = context.read<PlaylistService>();
    if (svc.playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Crea prima una playlist dalla scheda Playlist.'),
        ),
      );
      return;
    }
    final chosen = await showModalBottomSheet<Playlist>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Aggiungi a playlist',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            ...svc.playlists.map(
              (p) => ListTile(
                leading: const Icon(Icons.queue_music,
                    color: Color(0xFF4FE3C0)),
                title: Text(p.name),
                subtitle: Text('${p.trackIds.length} brani'),
                trailing: p.trackIds.contains(item.id)
                    ? const Icon(Icons.check, color: Colors.green)
                    : null,
                onTap: () => Navigator.pop(ctx, p),
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && context.mounted) {
      svc.addTrack(chosen, item.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Aggiunto a "${chosen.name}"')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusLabel = switch (item.status) {
      DlStatus.queued => 'In coda',
      DlStatus.downloading => 'Download…',
      DlStatus.done => _fmtBytes(item.bytes),
      DlStatus.error => 'Errore',
      DlStatus.cancelled => 'Annullato',
    };
    final statusColor = switch (item.status) {
      DlStatus.done => Colors.green,
      DlStatus.error || DlStatus.cancelled => Colors.red,
      _ => Colors.orange,
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  item.audio ? Icons.music_note : Icons.videocam,
                  color: const Color(0xFF4FE3C0),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.fileName ?? item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ],
                  ),
                ),
                Text(statusLabel, style: TextStyle(fontSize: 11, color: statusColor)),
              ],
            ),
            if (item.status == DlStatus.downloading ||
                item.status == DlStatus.queued) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: item.progress >= 0 ? item.progress : null,
                minHeight: 4,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation(Color(0xFF2DD4A8)),
              ),
            ],
            if (item.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  item.error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.red.shade200),
                ),
              ),
            if (item.status == DlStatus.done && item.filePath != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Riproduci'),
                    onPressed: () async {
                      final player = context.read<PlayerService>();
                      final dm = context.read<DownloadManager>();
                      final tracks = dm.items
                          .where((e) => e.finished && e.filePath != null)
                          .map((e) => LocalTrack(
                                id: e.id,
                                title: e.fileName ?? e.label,
                                filePath: e.filePath!,
                              ))
                          .toList();
                      final start = tracks.indexWhere((t) => t.id == item.id);
                      await player.playQueue(tracks, start: start < 0 ? 0 : start);
                    },
                  ),
                  IconButton(
                    tooltip: 'Aggiungi a playlist',
                    icon: const Icon(Icons.playlist_add, size: 18),
                    onPressed: () => _addToPlaylist(context, item),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => context.read<DownloadManager>().remove(item),
                  ),
                ],
              ),
            if (item.status == DlStatus.downloading)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Annulla'),
                  onPressed: () => context.read<DownloadManager>().cancel(item.id),
                ),
              ),
            if (item.failed)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Riprova'),
                  onPressed: () => context.read<DownloadManager>().retry(item),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
