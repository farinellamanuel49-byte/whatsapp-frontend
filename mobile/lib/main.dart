import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api_client.dart';
import 'apple_music_service.dart';
import 'config.dart';
import 'download_manager.dart';
import 'lora_service.dart';
import 'player_service.dart';
import 'playlist_service.dart';
import 'screens/apple_music_page.dart';
import 'screens/downloads_page.dart';
import 'screens/lora_page.dart';
import 'screens/playlists_page.dart';
import 'screens/search_page.dart';
import 'sync_service.dart';
import 'widgets/player_bar.dart';
import 'youtube_music_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  await settings.load();

  final api = ApiClient(settings);
  final appleMusic = AppleMusicService(settings);
  final downloads = DownloadManager(api);
  final playlists = PlaylistService();
  final ytMusic = YouTubeMusicService();
  final sync = SyncService(settings);
  final lora = LoraService();

  // A fine download: upload al Pi (se configurato), poi sync store
  // musicali (YouTube Music Android / Apple Music iOS).
  downloads.onDone = (item) async {
    if (!item.audio || item.filePath == null) return;
    if (sync.configured && settings.syncAutoUpload) {
      try {
        await sync.uploadAndSync(item.filePath!, item.fileName ?? item.id);
      } catch (_) {
        // La sync Pi non deve mai bloccare il flusso principale.
      }
    }
    if (item.syncTerm.isEmpty) return;
    if (ytMusic.supported && ytMusic.configured) {
      await ytMusic.syncQuery(item.syncTerm);
    } else {
      await appleMusic.autoSyncTrack(item.syncTerm);
    }
  };

  await downloads.init();
  await playlists.init();
  await ytMusic.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider.value(value: downloads),
        ChangeNotifierProvider.value(value: playlists),
        ChangeNotifierProvider.value(value: ytMusic),
        ChangeNotifierProvider.value(value: sync),
        ChangeNotifierProvider.value(value: lora),
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
      const PlaylistsPage(),
      if (widget.showAppleMusic) const AppleMusicPage(),
      if (widget.showAppleMusic) const LoraPage(),
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
          const NavigationDestination(
            icon: Icon(Icons.queue_music),
            label: 'Playlist',
          ),
          if (widget.showAppleMusic) ...[
            const NavigationDestination(
              icon: Icon(Icons.apple),
              label: 'Apple Music',
            ),
            const NavigationDestination(
              icon: Icon(Icons.sync_alt),
              label: 'Lora',
            ),
          ],
        ],
      ),
    );
  }
}
