import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../player_service.dart';

/// Mini-player fisso in fondo: brano corrente, play/pausa, skip.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.music_note, color: Color(0xFF4FE3C0), size: 22),
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
                      style: const TextStyle(fontSize: 13, color: Colors.white),
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
                                  ? (pos.inMilliseconds / total.inMilliseconds)
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
              IconButton(
                icon: const Icon(Icons.skip_previous, color: Colors.white70),
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
        ),
      ),
    );
  }
}
