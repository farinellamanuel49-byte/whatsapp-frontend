import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Traccia locale pronta per la riproduzione.
class LocalTrack {
  LocalTrack({required this.id, required this.title, required this.filePath});
  final String id;
  final String title;
  final String filePath;
}

/// Modalità ripetizione: come nei servizi di streaming.
enum RepeatMode { off, all, one }

/// Player audio per i brani scaricati. Supporta coda, shuffle e repeat.
/// Su iOS può convivere con MusicKit: quando parti Apple Music la coda
/// locale viene messa in pausa.
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

  RepeatMode repeatMode = RepeatMode.off;
  bool _shuffleEnabled = false;

  Stream<Duration> get positionStream => player.positionStream;
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  Stream<int?> get currentIndexStream => player.currentIndexStream;
  Stream<bool> get shuffleStream => player.shuffleModeEnabledStream;
  Stream<LoopMode> get loopModeStream => player.loopModeStream;

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
    if (!player.hasNext) {
      // Con repeat "tutto" just_audio riavvia da solo; se siamo alla fine
      // e repeat è spento, niente da fare.
      return;
    }
    await player.seekToNext();
  }

  Future<void> previous() async {
    if (player.position.inSeconds > 3 || !player.hasPrevious) {
      await player.seek(Duration.zero);
      return;
    }
    await player.seekToPrevious();
  }

  /// Shuffle on/off sulle sorgenti correnti (come Spotify).
  Future<void> toggleShuffle() async {
    _shuffleEnabled = !_shuffleEnabled;
    await player.setShuffleModeEnabled(_shuffleEnabled);
    notifyListeners();
  }

  /// Cicla la modalità ripetizione: off → tutto → uno → off.
  Future<void> cycleRepeat() async {
    repeatMode = switch (repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    await player.setLoopMode(switch (repeatMode) {
      RepeatMode.off => LoopMode.off,
      RepeatMode.all => LoopMode.all,
      RepeatMode.one => LoopMode.one,
    });
    notifyListeners();
  }

  Future<void> seek(Duration position) => player.seek(position);

  Future<void> stop() async {
    await player.stop();
    index = -1;
    queue = const [];
    repeatMode = RepeatMode.off;
    _shuffleEnabled = false;
    await player.setLoopMode(LoopMode.off);
    await player.setShuffleModeEnabled(false);
    notifyListeners();
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }
}
