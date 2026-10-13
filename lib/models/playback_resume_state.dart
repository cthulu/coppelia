import 'media_item.dart';

/// Snapshot of playback for resuming later.
class PlaybackResumeState {
  /// Creates a playback resume snapshot.
  const PlaybackResumeState({
    required this.track,
    required this.position,
    this.queue = const [],
    this.currentIndex = 0,
  });

  /// Track that was last playing.
  final MediaItem track;

  /// Last known playback position.
  final Duration position;

  /// Queue in playback order, including repeated songs.
  final List<MediaItem> queue;
  final int currentIndex;

  /// Serializes the resume snapshot.
  Map<String, dynamic> toJson() => {
        'track': track.toJson(),
        'positionMs': position.inMilliseconds,
        'queue': queue.map((item) => item.toJson()).toList(),
        'currentIndex': currentIndex,
      };

  /// Restores a resume snapshot from JSON.
  static PlaybackResumeState? fromJson(Map<String, dynamic> json) {
    final trackJson = json['track'] as Map<String, dynamic>?;
    if (trackJson == null) {
      return null;
    }
    final positionMs = json['positionMs'] as int? ?? 0;
    final track = MediaItem.fromJson(trackJson);
    final queueJson = json['queue'] as List<dynamic>?;
    final queue = queueJson == null || queueJson.isEmpty
        ? [track]
        : queueJson
            .map((item) => MediaItem.fromJson(item as Map<String, dynamic>))
            .toList();
    final index = json['currentIndex'] as int? ?? 0;
    if (index < 0 || index >= queue.length) {
      return PlaybackResumeState(
        track: track,
        position: Duration(milliseconds: positionMs),
        queue: [track],
      );
    }
    return PlaybackResumeState(
      track: queue[index],
      position: Duration(milliseconds: positionMs),
      queue: queue,
      currentIndex: index,
    );
  }
}
