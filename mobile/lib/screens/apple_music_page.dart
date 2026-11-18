import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../apple_music_service.dart';
import '../screens/settings_dialog.dart';

/// Scheda Apple Music (solo iOS): streaming della libreria e del catalogo.
/// I brani non sono scaricabili (DRM): si riproducono in streaming.
class AppleMusicPage extends StatefulWidget {
  const AppleMusicPage({super.key});

  @override
  State<AppleMusicPage> createState() => _AppleMusicPageState();
}

class _AppleMusicPageState extends State<AppleMusicPage> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _results = const [];
  List<Map<String, dynamic>> _library = const [];
  bool _searching = false;
  bool _loadingLibrary = false;
  String? _error;

  AppleMusicService get _svc => context.read<AppleMusicService>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final svc = context.read<AppleMusicService>();
      if (svc.supported && !svc.connected && svc.settings.appleDeveloperToken.isNotEmpty) {
        svc.connect();
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _doSearch() async {
    final term = _search.text.trim();
    if (term.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await _svc.searchCatalog(term);
      if (mounted) setState(() => _results = results);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _loadLibrary() async {
    setState(() {
      _loadingLibrary = true;
      _error = null;
    });
    try {
      final songs = await _svc.librarySongs();
      if (mounted) setState(() => _library = songs);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingLibrary = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<AppleMusicService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Apple Music'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsDialog(context),
          ),
        ],
      ),
      body: !svc.supported
          ? const Center(child: Text('Apple Music è disponibile solo su iOS.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (!svc.connected)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Connetti il tuo account Apple Music',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            svc.settings.appleDeveloperToken.isEmpty
                                ? 'Configura prima il developer token nelle Impostazioni.'
                                : 'Verrà chiesta l\'autorizzazione Apple Music.',
                            style: const TextStyle(fontSize: 12.5, color: Colors.white54),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: svc.busy ? null : svc.connect,
                                icon: svc.busy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.link),
                                label: const Text('Connetti'),
                              ),
                              TextButton.icon(
                                onPressed: () => showSettingsDialog(context),
                                icon: const Icon(Icons.settings_outlined),
                                label: const Text('Token'),
                              ),
                            ],
                          ),
                          if (svc.error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                svc.error!,
                                style: TextStyle(fontSize: 12, color: Colors.red.shade200),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (svc.connected) ...[
                  if (svc.nowPlayingTitle != null)
                    Card(
                      color: const Color(0xFF2DD4A8).withValues(alpha: .08),
                      child: ListTile(
                        leading: const Icon(Icons.play_circle_fill,
                            color: Color(0xFF4FE3C0)),
                        title: Text(svc.nowPlayingTitle!,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: const Text('In riproduzione · streaming'),
                        trailing: IconButton(
                          icon: const Icon(Icons.pause_circle_outline),
                          onPressed: svc.pause,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      hintText: 'Cerca nel catalogo Apple Music',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: _searching
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.search),
                        onPressed: _searching ? null : _doSearch,
                      ),
                    ),
                    onSubmitted: (_) => _doSearch(),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _loadingLibrary ? null : _loadLibrary,
                    icon: _loadingLibrary
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.library_music_outlined),
                    label: const Text('Carica la mia libreria'),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        _error!,
                        style: TextStyle(color: Colors.red.shade200, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (_results.isNotEmpty) ...[
                    const Text('Risultati catalogo',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ..._results.map((s) => _SongTile(song: s, onPlay: () => _play(s))),
                    const SizedBox(height: 16),
                  ],
                  if (_library.isNotEmpty) ...[
                    const Text('La mia libreria',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ..._library.map((s) => _SongTile(song: s, onPlay: () => _play(s))),
                  ],
                ],
              ],
            ),
    );
  }

  Future<void> _play(Map<String, dynamic> song) async {
    setState(() => _error = null);
    try {
      await _svc.playSong(song);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }
}

class _SongTile extends StatelessWidget {
  const _SongTile({required this.song, required this.onPlay});
  final Map<String, dynamic> song;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final attrs = song['attributes'];
    final title = attrs is Map
        ? (attrs['name'] ?? attrs['songName'] ?? 'Brano').toString()
        : 'Brano';
    final artist = attrs is Map ? attrs['artistName']?.toString() : null;
    final artwork = attrs is Map ? attrs['artwork'] : null;

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: artwork is Map && artwork['url'] != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                artwork['url'].toString().replaceAll('{w}', '100').replaceAll('{h}', '100'),
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.music_note, size: 30),
              ),
            )
          : const Icon(Icons.music_note, size: 30),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: artist != null
          ? Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis)
          : null,
      trailing: IconButton(icon: const Icon(Icons.play_arrow), onPressed: onPlay),
      onTap: onPlay,
    );
  }
}
