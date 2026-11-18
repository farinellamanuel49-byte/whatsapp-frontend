import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../download_manager.dart';
import '../screens/settings_dialog.dart';

/// Scheda "Cerca": ricerca per titolo o link diretto, poi avvia il download.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _controller = TextEditingController();
  bool _urlMode = false;
  bool _audio = true;
  int _quality = 720;
  bool _busy = false;
  bool? _apiOnline;
  String? _message;
  bool _messageError = false;

  @override
  void initState() {
    super.initState();
    _checkHealth();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _checkHealth() async {
    final api = context.read<ApiClient>();
    api.syncBaseUrl();
    final ok = await api.health();
    if (mounted) setState(() => _apiOnline = ok);
  }

  Future<void> _download() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() {
        _message = 'Inserisci un titolo o un link.';
        _messageError = true;
      });
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final dm = context.read<DownloadManager>();
      await dm.start(
        query: _urlMode ? null : value,
        url: _urlMode ? value : null,
        audio: _audio,
        quality: _audio ? 0 : _quality,
      );
      if (mounted) {
        setState(() {
          _message = 'Download avviato: $value';
          _messageError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = e.toString();
          _messageError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloader Musicale'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => showSettingsDialog(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              _ModeChip(
                label: 'Ricerca',
                selected: !_urlMode,
                onTap: () => setState(() => _urlMode = false),
              ),
              const SizedBox(width: 8),
              _ModeChip(
                label: 'Link diretto',
                selected: _urlMode,
                onTap: () => setState(() => _urlMode = true),
              ),
              const Spacer(),
              _HealthPill(
                online: _apiOnline,
                onRetry: _checkHealth,
              ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: _urlMode ? 'Link (YouTube, Instagram, TikTok…)' : 'Titolo di ricerca',
              hintText: _urlMode
                  ? 'https://www.youtube.com/watch?v=…'
                  : 'es. Artist - Titolo',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
            ),
            onSubmitted: (_) => _download(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Audio')),
                  ButtonSegment(value: false, label: Text('Video')),
                ],
                selected: {_audio},
                onSelectionChanged: (s) => setState(() => _audio = s.first),
              ),
              if (!_audio)
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 360, label: Text('360p')),
                    ButtonSegment(value: 720, label: Text('720p')),
                    ButtonSegment(value: 1080, label: Text('1080p')),
                  ],
                  selected: {_quality},
                  onSelectionChanged: (s) => setState(() => _quality = s.first),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _download,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download),
                label: const Text('Scarica'),
              ),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _messageError
                    ? Colors.red.withValues(alpha: .08)
                    : Colors.green.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _messageError
                      ? Colors.red.withValues(alpha: .3)
                      : Colors.green.withValues(alpha: .3),
                ),
              ),
              child: Text(
                _message!,
                style: TextStyle(
                  color: _messageError ? Colors.red.shade200 : Colors.green.shade200,
                  fontSize: 13,
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            'I file vengono salvati nella app e sono riproducibili dalla scheda Download.\n'
            'Su iOS puoi anche riprodurre in streaming la tua libreria Apple Music.',
            style: TextStyle(color: Colors.white54, fontSize: 12.5, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class _HealthPill extends StatelessWidget {
  const _HealthPill({required this.online, required this.onRetry});
  final bool? online;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (online) {
      true => ('API online', Colors.green),
      false => ('API offline', Colors.red),
      null => ('verifica…', Colors.orange),
    };
    return ActionChip(
      avatar: Icon(Icons.circle, size: 10, color: color),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onPressed: onRetry,
    );
  }
}
