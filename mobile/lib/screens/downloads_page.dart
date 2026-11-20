import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../apple_music_service.dart';
import '../download_manager.dart';
import '../player_service.dart';
import '../playlist_service.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Download'),
        actions: [
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
