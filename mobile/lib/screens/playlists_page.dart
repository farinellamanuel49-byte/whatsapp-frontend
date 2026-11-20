import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../download_manager.dart';
import '../player_service.dart';
import '../playlist_service.dart';

/// Scheda "Playlist": crea e gestisce playlist di brani scaricati.
class PlaylistsPage extends StatelessWidget {
  const PlaylistsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final playlists = context.watch<PlaylistService>();
    final dm = context.watch<DownloadManager>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Playlist'),
        actions: [
          IconButton(
            tooltip: 'Nuova playlist',
            icon: const Icon(Icons.add),
            onPressed: () => _createPlaylist(context),
          ),
        ],
      ),
      body: playlists.playlists.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.queue_music, size: 64, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text(
                    'Nessuna playlist.\nCrea la prima e aggiungi i brani scaricati.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Crea playlist'),
                    onPressed: () => _createPlaylist(context),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: playlists.playlists.length,
              itemBuilder: (context, i) {
                final p = playlists.playlists[i];
                final available = p.trackIds
                    .where((id) => dm.items.any(
                        (e) => e.id == id && e.finished && e.filePath != null))
                    .length;
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: const Icon(Icons.queue_music,
                        color: Color(0xFF4FE3C0)),
                    title: Text(p.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('$available brani'),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'rename') {
                          await _renamePlaylist(context, p);
                        } else if (v == 'delete') {
                          await _deletePlaylist(context, p);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rinomina')),
                        PopupMenuItem(value: 'delete', child: Text('Elimina')),
                      ],
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => PlaylistDetailPage(playlist: p),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _createPlaylist(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nuova playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nome playlist'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Crea'),
          ),
        ],
      ),
    );
    if (name != null) {
      context.read<PlaylistService>().create(name);
    }
  }

  Future<void> _renamePlaylist(
      BuildContext context, Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rinomina playlist'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Salva'),
          ),
        ],
      ),
    );
    if (name != null) {
      await context.read<PlaylistService>().rename(playlist, name);
    }
  }

  Future<void> _deletePlaylist(
      BuildContext context, Playlist playlist) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminare "${playlist.name}"?'),
        content: const Text('I brani scaricati non verranno toccati.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await context.read<PlaylistService>().delete(playlist);
      if (context.mounted) Navigator.of(context).maybePop();
    }
  }
}

/// Dettaglio di una playlist: brani, riproduzione, shuffle, rimozione.
class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage({super.key, required this.playlist});
  final Playlist playlist;

  List<DownloadItem> _tracks(BuildContext context) {
    final dm = context.read<DownloadManager>();
    return playlist.trackIds
        .map((id) => dm.items.where((e) => e.id == id).firstOrNull)
        .whereType<DownloadItem>()
        .where((e) => e.finished && e.filePath != null)
        .toList();
  }

  Future<void> _playAll(BuildContext context, {bool shuffle = false}) async {
    final tracks = _tracks(context)
        .map((e) => LocalTrack(
              id: e.id,
              title: e.fileName ?? e.label,
              filePath: e.filePath!,
            ))
        .toList();
    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nessun brano disponibile in playlist.')),
      );
      return;
    }
    final player = context.read<PlayerService>();
    await player.playQueue(tracks);
    if (shuffle) await player.toggleShuffle();
    if (context.mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    context.watch<PlaylistService>(); // rebuild su modifiche playlist
    final tracks = _tracks(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(playlist.name),
        actions: [
          IconButton(
            tooltip: 'Riproduci in ordine',
            icon: const Icon(Icons.play_arrow),
            onPressed: () => _playAll(context),
          ),
          IconButton(
            tooltip: 'Riproduci casuale',
            icon: const Icon(Icons.shuffle),
            onPressed: () => _playAll(context, shuffle: true),
          ),
        ],
      ),
      body: tracks.isEmpty
          ? Center(
              child: Text(
                'Playlist vuota.\nAggiungi brani dalla scheda Download.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: tracks.length,
              onReorder: (oldI, newI) {
                final orderedIds = tracks.map((t) => t.id).toList();
                if (newI > oldI) newI--;
                final moved = orderedIds.removeAt(oldI);
                orderedIds.insert(newI, moved);
                context
                    .read<PlaylistService>()
                    .reorderVisible(playlist, orderedIds);
              },
              itemBuilder: (context, i) {
                final item = tracks[i];
                return Card(
                  key: ValueKey(item.id),
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.music_note,
                        color: Color(0xFF4FE3C0), size: 20),
                    title: Text(item.fileName ?? item.label,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(item.label,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 11, color: Colors.white54)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.play_arrow, size: 20),
                          onPressed: () async {
                            final player = context.read<PlayerService>();
                            await player.playQueue(
                              tracks
                                  .map((e) => LocalTrack(
                                        id: e.id,
                                        title: e.fileName ?? e.label,
                                        filePath: e.filePath!,
                                      ))
                                  .toList(),
                              start: i,
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline,
                              size: 20, color: Colors.redAccent),
                          onPressed: () => context
                              .read<PlaylistService>()
                              .removeTrack(playlist, item.id),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
