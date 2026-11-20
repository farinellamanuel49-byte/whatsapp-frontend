import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Una playlist contiene gli id dei DownloadItem (solo brani scaricati).
class Playlist {
  Playlist({required this.id, required this.name, List<String>? trackIds})
      : trackIds = trackIds ?? [];

  final String id;
  String name;
  final List<String> trackIds;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'trackIds': trackIds};

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Playlist',
        trackIds: (j['trackIds'] as List?)?.cast<String>() ?? [],
      );
}

/// Gestisce playlist locali persistite in documents/playlists.json.
class PlaylistService extends ChangeNotifier {
  final List<Playlist> playlists = [];
  final _uuid = const Uuid();
  File? _file;
  Timer? _timer;

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _file = File('${docs.path}${Platform.pathSeparator}playlists.json');
    try {
      final raw = await _file!.readAsString();
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      playlists
        ..clear()
        ..addAll(list.map(Playlist.fromJson));
    } catch (_) {}
    notifyListeners();
  }

  void _persist() {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), () async {
      try {
        await _file?.writeAsString(
            jsonEncode(playlists.map((p) => p.toJson()).toList()));
      } catch (_) {}
    });
  }

  Playlist create(String name) {
    final p = Playlist(id: _uuid.v4(), name: name.trim().isEmpty ? 'Playlist' : name.trim());
    playlists.add(p);
    notifyListeners();
    _persist();
    return p;
  }

  Future<void> rename(Playlist p, String name) async {
    p.name = name.trim().isEmpty ? p.name : name.trim();
    notifyListeners();
    _persist();
  }

  Future<void> delete(Playlist p) async {
    playlists.remove(p);
    notifyListeners();
    _persist();
  }

  void addTrack(Playlist p, String trackId) {
    if (p.trackIds.contains(trackId)) return;
    p.trackIds.add(trackId);
    notifyListeners();
    _persist();
  }

  void removeTrack(Playlist p, String trackId) {
    p.trackIds.remove(trackId);
    notifyListeners();
    _persist();
  }

  /// Riordina la playlist dato l'ordine dei soli brani visibili
  /// (quelli ancora presenti tra i download). Gli id non più
  /// validi vengono mantenuti in coda.
  void reorderVisible(Playlist p, List<String> orderedVisibleIds) {
    final stale = p.trackIds
        .where((id) => !orderedVisibleIds.contains(id))
        .toList();
    p.trackIds
      ..clear()
      ..addAll(orderedVisibleIds)
      ..addAll(stale);
    notifyListeners();
    _persist();
  }

  /// Sposta un brano dentro la playlist (per riordino manuale).
  void moveTrack(Playlist p, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final id = p.trackIds.removeAt(oldIndex);
    p.trackIds.insert(newIndex.clamp(0, p.trackIds.length), id);
    notifyListeners();
    _persist();
  }

  /// True se il brano è in almeno una playlist.
  bool containsTrack(String trackId) =>
      playlists.any((p) => p.trackIds.contains(trackId));

  List<Playlist> playlistsOf(String trackId) =>
      playlists.where((p) => p.trackIds.contains(trackId)).toList();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
