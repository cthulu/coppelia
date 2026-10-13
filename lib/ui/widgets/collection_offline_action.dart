import 'package:flutter/material.dart';

import '../../models/download_task.dart';
import '../../models/media_item.dart';

/// Offline action shared by album, artist, and playlist headers.
class CollectionOfflineActionState {
  const CollectionOfflineActionState({
    required this.canDownload,
    required this.isOfflineReady,
    required this.isOfflinePending,
    required this.hasFailedDownloads,
  });

  factory CollectionOfflineActionState.forTracks({
    required List<MediaItem> tracks,
    required bool Function(MediaItem track) isTrackAvailable,
    required String Function(MediaItem track) trackKey,
    required List<DownloadTask> downloadQueue,
  }) {
    final keys = tracks.map(trackKey).toSet();
    final downloads = downloadQueue
        .where((task) => keys.contains(trackKey(task.track)))
        .toList();
    return CollectionOfflineActionState(
      canDownload: tracks.isNotEmpty,
      isOfflineReady: tracks.isNotEmpty &&
          tracks.every(isTrackAvailable) &&
          downloads.isEmpty,
      isOfflinePending: downloads.any((task) =>
          task.status != DownloadStatus.failed &&
          task.status != DownloadStatus.stopped),
      hasFailedDownloads: downloads.any((task) =>
          task.status == DownloadStatus.failed ||
          task.status == DownloadStatus.stopped),
    );
  }

  final bool canDownload;
  final bool isOfflineReady;
  final bool isOfflinePending;
  final bool hasFailedDownloads;

  String get label =>
      isOfflinePending ? 'Making Available Offline...' : tooltip;

  String get tooltip => isOfflinePending
      ? 'Cancel Offline Request'
      : isOfflineReady
          ? 'Remove from Offline'
          : hasFailedDownloads
              ? 'Retry Offline Download'
              : 'Make Available Offline';

  IconData get icon =>
      isOfflineReady ? Icons.download_done_rounded : Icons.download_rounded;
}
