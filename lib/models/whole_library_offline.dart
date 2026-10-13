import 'media_item.dart';

/// Preview details for downloading an entire library for offline playback.
class WholeLibraryOfflinePreview {
  /// Creates a whole-library offline preview.
  const WholeLibraryOfflinePreview({
    required this.tracks,
    required this.trackCount,
    required this.cachedTrackCount,
    required this.estimatedTotalBytes,
    required this.estimatedRemainingBytes,
    required this.downloadsWifiOnly,
    required this.downloadsPaused,
    required this.wholeLibraryPinnedTrackCount,
  });

  /// Tracks included in the whole-library action.
  final List<MediaItem> tracks;

  /// Total number of tracks in the library snapshot.
  final int trackCount;

  /// Tracks already cached on disk.
  final int cachedTrackCount;

  /// Estimated final on-disk size for the whole library.
  final int estimatedTotalBytes;

  /// Estimated additional bytes still left to download.
  final int estimatedRemainingBytes;

  /// True when downloads are limited to Wi-Fi.
  final bool downloadsWifiOnly;

  /// True when downloads are currently paused.
  final bool downloadsPaused;

  /// Tracks currently tracked as part of a prior whole-library action.
  final int wholeLibraryPinnedTrackCount;
}

/// Result summary after queueing an entire library for offline playback.
class WholeLibraryOfflineResult {
  /// Creates a whole-library offline result.
  const WholeLibraryOfflineResult({
    required this.trackCount,
    required this.newlyPinnedCount,
    required this.newlyQueuedCount,
    required this.retriedFailedCount,
    required this.alreadyPinnedCount,
    required this.wholeLibraryPinnedTrackCount,
  });

  /// Tracks inspected during the operation.
  final int trackCount;

  /// Tracks newly pinned by this action.
  final int newlyPinnedCount;

  /// Tracks newly added to the download queue.
  final int newlyQueuedCount;

  /// Failed downloads reset back to queued.
  final int retriedFailedCount;

  /// Tracks that were already pinned before this action.
  final int alreadyPinnedCount;

  /// Tracks still tracked as part of the whole-library action.
  final int wholeLibraryPinnedTrackCount;
}

/// Result summary after undoing a whole-library offline action.
class WholeLibraryOfflineRemovalResult {
  /// Creates a whole-library offline removal result.
  const WholeLibraryOfflineRemovalResult({
    required this.removedTrackCount,
  });

  /// Tracks removed from the whole-library offline set.
  final int removedTrackCount;
}
