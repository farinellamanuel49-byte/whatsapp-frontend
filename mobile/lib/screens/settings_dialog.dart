import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../apple_music_service.dart';
import '../config.dart';
import '../youtube_music_service.dart';

/// Impostazioni: URL del proxy API e (iOS) token Apple Music.
Future<void> showSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _SettingsDialog(),
  );
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog();

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _devToken;
  late final TextEditingController _userToken;
  late final TextEditingController _storefront;
  late final TextEditingController _sapisid;
  late final TextEditingController _syncUrl;
  late final TextEditingController _syncToken;
  late bool _syncAuto;

  @override
  void initState() {
    super.initState();
    final s = context.read<Settings>();
    _baseUrl = TextEditingController(text: s.baseUrl);
    _devToken = TextEditingController(text: s.appleDeveloperToken);
    _userToken = TextEditingController(text: s.appleUserToken);
    _storefront = TextEditingController(text: s.appleStorefront);
    _sapisid = TextEditingController(
        text: context.read<YouTubeMusicService>().sapisid);
    _syncUrl = TextEditingController(text: s.syncServerUrl);
    _syncToken = TextEditingController(text: s.syncToken);
    _syncAuto = s.syncAutoUpload;
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _devToken.dispose();
    _userToken.dispose();
    _storefront.dispose();
    _sapisid.dispose();
    _syncUrl.dispose();
    _syncToken.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final s = context.read<Settings>();
    await s.setBaseUrl(_baseUrl.text);
    await s.saveAppleConfig(
      developerToken: _devToken.text,
      userToken: _userToken.text,
      storefront: _storefront.text,
    );
    await context.read<YouTubeMusicService>().saveSapisid(_sapisid.text);
    await s.saveSyncConfig(
      serverUrl: _syncUrl.text,
      token: _syncToken.text,
      autoUpload: _syncAuto,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = context.read<AppleMusicService>().supported;
    final isAndroid = context.read<YouTubeMusicService>().supported;
    return AlertDialog(
      title: const Text('Impostazioni'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _baseUrl,
              decoration: const InputDecoration(
                labelText: 'URL server API',
                hintText: 'http://192.168.1.10:8080',
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            if (isIOS) ...[
              const Divider(),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Apple Music (solo iOS)',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _devToken,
                decoration: const InputDecoration(
                  labelText: 'Developer token (JWT)',
                  hintText: 'eyJ…',
                ),
                obscureText: true,
              ),
              TextField(
                controller: _userToken,
                decoration: const InputDecoration(
                  labelText: 'Music-User-Token (opzionale)',
                  hintText: 'per libreria e store privato',
                ),
                obscureText: true,
              ),
              TextField(
                controller: _storefront,
                decoration: const InputDecoration(
                  labelText: 'Storefront',
                  hintText: 'it',
                ),
              ),
            ],
            if (isAndroid) ...[
              const Divider(),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('YouTube Music (solo Android)',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _sapisid,
                decoration: const InputDecoration(
                  labelText: 'Cookie SAPISID',
                  hintText: 'da music.youtube.com → DevTools → Cookies',
                ),
                obscureText: true,
              ),
              const SizedBox(height: 4),
              const Text(
                'Come trovarlo: apri music.youtube.com nel browser, '
                'F12 → Application → Cookies → copia il valore di SAPISID. '
                'I brani scaricati verranno aggiunti ai "Mi piace" di YouTube Music.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
            ],
            const Divider(),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Sincronizzazione iPhone (server Pi)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _syncUrl,
              decoration: const InputDecoration(
                labelText: 'URL server sync',
                hintText: 'https://pi.example.com:8787',
              ),
              keyboardType: TextInputType.url,
            ),
            TextField(
              controller: _syncToken,
              decoration: const InputDecoration(
                labelText: 'Token sync',
                hintText: 'SYNC_TOKEN del Pi',
              ),
              obscureText: true,
            ),
            CheckboxListTile(
              value: _syncAuto,
              onChanged: (v) => setState(() => _syncAuto = v ?? true),
              title: const Text('Carica automaticamente i download',
                  style: TextStyle(fontSize: 14)),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            const Text(
              'I brani scaricati vengono caricati sul Pi e sincronizzati '
              'nella libreria Music dell\'iPhone via rustunes.',
              style: TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annulla'),
        ),
        FilledButton(onPressed: _save, child: const Text('Salva')),
      ],
    );
  }
}
