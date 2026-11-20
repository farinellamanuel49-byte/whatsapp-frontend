import 'package:flutter/material.dart' hide RepeatMode;
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../player_service.dart';

/// Mini-player fisso in fondo: brano corrente, play/pausa, skip,
/// shuffle e repeat come nei servizi di streaming.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  IconData _repeatIcon(RepeatMode mode) => switch (mode) {
        RepeatMode.off => Icons.repeat,
        RepeatMode.all => Icons.repeat,
        RepeatMode.one => Icons.repeat_one,
      };

  Color _repeatColor(RepeatMode mode) =>
      mode == RepeatMode.off ? Colors.white38 : const Color(0xFF4FE3C0);

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerService>();
    final track = player.current;
    if (track == null) return const SizedBox.shrink();

    return Material(
      color: const Color(0xFF0E242B),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.music_note,
                      color: Color(0xFF4FE3C0), size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white),
                        ),
                        StreamBuilder<Duration?>(
                          stream: player.durationStream,
                          builder: (context, snap) {
                            final dur = snap.data;
                            return StreamBuilder<Duration>(
                              stream: player.positionStream,
                              builder: (context, posSnap) {
                                final pos = posSnap.data ?? Duration.zero;
                                final total = dur ?? Duration.zero;
                                return LinearProgressIndicator(
                                  value: total.inMilliseconds > 0
                                      ? (pos.inMilliseconds /
                                              total.inMilliseconds)
                                          .clamp(0.0, 1.0)
                                      : null,
                                  minHeight: 2,
                                  backgroundColor: Colors.white12,
                                  valueColor: const AlwaysStoppedAnimation(
                                      Color(0xFF2DD4A8)),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  StreamBuilder<bool>(
                    stream: player.shuffleStream,
                    initialData: false,
                    builder: (context, snap) {
                      final on = snap.data ?? false;
                      return IconButton(
                        icon: Icon(
                          Icons.shuffle,
                          size: 20,
                          color: on
                              ? const Color(0xFF4FE3C0)
                              : Colors.white38,
                        ),
                        onPressed: player.toggleShuffle,
                      );
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      _repeatIcon(player.repeatMode),
                      size: 20,
                      color: _repeatColor(player.repeatMode),
                    ),
                    onPressed: player.cycleRepeat,
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_previous,
                        color: Colors.white70),
                    onPressed: player.previous,
                  ),
                  StreamBuilder<PlayerState>(
                    stream: player.playerStateStream,
                    builder: (context, snap) {
                      final playing = snap.data?.playing ?? false;
                      return IconButton(
                        icon: Icon(
                          playing ? Icons.pause : Icons.play_arrow,
                          color: const Color(0xFF4FE3C0),
                          size: 30,
                        ),
                        onPressed: player.toggle,
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next, color: Colors.white70),
                    onPressed: player.next,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
