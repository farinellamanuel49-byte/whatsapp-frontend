import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Traccia locale pronta per la riproduzione.
class LocalTrack {
  LocalTrack({required this.id, required this.title, required this.filePath});
  final String id;
  final String title;
  final String filePath;
}

/// Player audio per i brani scaricati. Su iOS può convivere con MusicKit:
/// quando parti Apple Music la coda locale viene messa in pausa.
class PlayerService extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();

  PlayerService() {
    player.currentIndexStream.listen((i) {
      if (i != null && i != index) {
        index = i;
        notifyListeners();
      }
    });
  }

  List<LocalTrack> queue = const [];
  int index = -1;

  Stream<Duration> get positionStream => player.positionStream;
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  Stream<int?> get currentIndexStream => player.currentIndexStream;

  bool get hasTrack => index >= 0 && index < queue.length;
  LocalTrack? get current => hasTrack ? queue[index] : null;

  Future<void> playQueue(List<LocalTrack> tracks, {int start = 0}) async {
    if (tracks.isEmpty) return;
    queue = List.of(tracks);
    await player.setAudioSources(
      tracks.map((t) => AudioSource.file(t.filePath, tag: t.id)).toList(),
      initialIndex: start.clamp(0, tracks.length - 1),
      initialPosition: Duration.zero,
    );
    index = start.clamp(0, tracks.length - 1);
    notifyListeners();
    await player.play();
  }

  Future<void> playAt(int i) async {
    if (i < 0 || i >= queue.length) return;
    index = i;
    await player.seek(Duration.zero, index: i);
    notifyListeners();
    await player.play();
  }

  Future<void> toggle() async {
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  Future<void> next() async {
    if (!player.hasNext) return;
    await player.seekToNext();
  }

  Future<void> previous() async {
    if (!player.hasPrevious) return;
    await player.seekToPrevious();
  }

  Future<void> seek(Duration position) => player.seek(position);

  Future<void> stop() async {
    await player.stop();
    index = -1;
    queue = const [];
    notifyListeners();
  }

  /// Suggerimento per la UI: con file corrotti just_audio passa al brano
  /// successivo della coda concatenata invece di fermarsi.
  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }
}
