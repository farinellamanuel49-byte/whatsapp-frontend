import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../lora_service.dart';

/// Pagina Lora: login Apple ID via WebView + diagnostica connessione
/// con l'API privata di Apple Music (amp-api).
class LoraPage extends StatefulWidget {
  const LoraPage({super.key});

  @override
  State<LoraPage> createState() => _LoraPageState();
}

class _LoraPageState extends State<LoraPage> {
  bool _showWeb = false;

  LoraService get _svc => context.read<LoraService>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _svc.probe());
  }

  Future<void> _login() async {
    setState(() => _showWeb = true);
    // la webview resta aperta: l'utente fa login, poi "Fine" rprobe
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lora — Apple Music Sync'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Riprova connessione',
            onPressed: () => _svc.probe(),
          ),
        ],
      ),
      body: _showWeb ? _buildWeb() : _buildHome(),
    );
  }

  Widget _buildWeb() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: const Color(0xFF1C1C1E),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Accedi con il tuo Apple ID qui sotto, poi premi "Fine".',
                  style: TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
              TextButton(
                onPressed: () async {
                  await _svc.probe();
                  if (mounted) setState(() => _showWeb = false);
                },
                child: const Text('Fine', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
        Expanded(
          child: WebViewWidget(controller: _svc.ensureController()),
        ),
      ],
    );
  }

  Widget _buildHome() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _svc.connected ? Icons.check_circle : Icons.error_outline,
                      color: _svc.connected ? Colors.green : Colors.orange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _svc.status,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Lora aggiunge i brani scaricati alla tua libreria Apple Music '
                  'usando la sessione web (serve un abbonamento Apple Music attivo).',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _login,
                  icon: const Icon(Icons.login),
                  label: Text(_svc.connected ? 'Ricollegati' : 'Accedi con Apple ID'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Diagnostica',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 220,
                  child: ListenableBuilder(
                    listenable: _svc,
                    builder: (context, _) {
                      if (_svc.log.isEmpty) {
                        return const Center(
                          child: Text('Nessun dato — premi rinfresca o login',
                              style: TextStyle(color: Colors.white38, fontSize: 12)),
                        );
                      }
                      return ListView.builder(
                        itemCount: _svc.log.length,
                        itemBuilder: (_, i) => Text(
                          _svc.log[i],
                          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
