import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api_client.dart';
import 'apple_music_service.dart';
import 'config.dart';
import 'download_manager.dart';
import 'player_service.dart';
import 'screens/apple_music_page.dart';
import 'screens/downloads_page.dart';
import 'screens/search_page.dart';
import 'widgets/player_bar.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await settings.load();

  final api = ApiClient(settings);
  final appleMusic = AppleMusicService(settings);
  final downloads = DownloadManager(api);

  // Su iOS: a fine download il brano viene cercato sul catalogo Apple Music
  // e aggiunto automaticamente alla libreria utente.
  downloads.onDone = (item) async {
    if (!item.audio || item.syncTerm.isEmpty) return;
    await appleMusic.autoSyncTrack(item.syncTerm);
  };

  await downloads.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider.value(value: downloads),
        ChangeNotifierProvider(create: (_) => PlayerService()),
        ChangeNotifierProvider.value(value: appleMusic),
      ],
      child: const MusicDownloaderApp(),
    ),
  );
}

class MusicDownloaderApp extends StatelessWidget {
  const MusicDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isIOS = context.read<AppleMusicService>().supported;
    return MaterialApp(
      title: 'Downloader Musicale',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2DD4A8),
          brightness: Brightness.dark,
          surface: const Color(0xFF0A1A1F),
        ),
        scaffoldBackgroundColor: const Color(0xFF0A1A1F),
        useMaterial3: true,
      ),
      home: _HomeShell(showAppleMusic: isIOS),
    );
  }
}

class _HomeShell extends StatefulWidget {
  const _HomeShell({required this.showAppleMusic});
  final bool showAppleMusic;

  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const SearchPage(),
      const DownloadsPage(),
      if (widget.showAppleMusic) const AppleMusicPage(),
    ];

    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: IndexedStack(index: _tab, children: pages),
          ),
          const PlayerBar(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.search),
            label: 'Cerca',
          ),
          const NavigationDestination(
            icon: Icon(Icons.download_done_outlined),
            label: 'Download',
          ),
          if (widget.showAppleMusic)
            const NavigationDestination(
              icon: Icon(Icons.apple),
              label: 'Apple Music',
            ),
        ],
      ),
    );
  }
}
