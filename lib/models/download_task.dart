import 'media_item.dart';

/// Status for an in-progress or queued download.
enum DownloadStatus {
  /// Waiting to be downloaded.
  queued,

  /// Blocked by Wi-Fi-only rules.
  waitingForWifi,

  /// Currently downloading.
  downloading,

  /// Download failed.
  failed,

  waitingToRetry,

  stopped,

  waitingForSignIn,
}

/// Represents a queued audio download with progress metadata.
class DownloadTask {
  /// Creates a download task.
  const DownloadTask({
    required this.track,
    required this.status,
    required this.queuedAt,
    this.requiresWifi = false,
    this.progress,
    this.totalBytes,
    this.downloadedBytes,
    this.errorMessage,
    this.attempts = 0,
    this.retryAt,
    this.userInitiated = false,
    this.retryableFailure = false,
  });

  /// Track to download.
  final MediaItem track;

  /// Current status.
  final DownloadStatus status;

  /// Download progress from 0-1, when available.
  final double? progress;

  /// Total bytes for the download, when known.
  final int? totalBytes;

  /// Bytes downloaded so far, when known.
  final int? downloadedBytes;

  /// Optional error message.
  final String? errorMessage;

  /// Timestamp when the task was enqueued.
  final DateTime queuedAt;

  /// True when this task can only run on Wi-Fi.
  final bool requiresWifi;

  final int attempts;
  final DateTime? retryAt;

  /// Whether the user selected this download, rather than automatic favorites.
  final bool userInitiated;
  final bool retryableFailure;

  DownloadTask reset({bool userInitiated = true}) => DownloadTask(
      track: track,
      status: DownloadStatus.queued,
      queuedAt: queuedAt,
      requiresWifi: requiresWifi,
      userInitiated: userInitiated);

  Map<String, dynamic> toJson() => {
        'track': track.toJson(),
        'status': status.name,
        'queuedAt': queuedAt.toIso8601String(),
        'requiresWifi': requiresWifi,
        'attempts': attempts,
        'retryAt': retryAt?.toIso8601String(),
        'errorMessage': errorMessage,
        'userInitiated': userInitiated,
        'retryableFailure': retryableFailure,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
        track:
            MediaItem.fromJson(Map<String, dynamic>.from(json['track'] as Map)),
        status: DownloadStatus.values.byName(json['status'] as String),
        queuedAt: DateTime.parse(json['queuedAt'] as String),
        requiresWifi: json['requiresWifi'] == true,
        attempts: json['attempts'] as int? ?? 0,
        retryAt: DateTime.tryParse(json['retryAt'] as String? ?? ''),
        errorMessage: json['errorMessage'] as String?,
        userInitiated: json['userInitiated'] == true,
        retryableFailure: json['retryableFailure'] == true,
      );

  /// Returns a copy with updated values.
  DownloadTask copyWith({
    MediaItem? track,
    DownloadStatus? status,
    double? progress,
    int? totalBytes,
    int? downloadedBytes,
    String? errorMessage,
    bool? requiresWifi,
    int? attempts,
    DateTime? retryAt,
    bool? retryableFailure,
  }) {
    return DownloadTask(
      track: track ?? this.track,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      errorMessage: errorMessage ?? this.errorMessage,
      queuedAt: queuedAt,
      requiresWifi: requiresWifi ?? this.requiresWifi,
      attempts: attempts ?? this.attempts,
      retryAt: retryAt ?? this.retryAt,
      userInitiated: userInitiated,
      retryableFailure: retryableFailure ?? this.retryableFailure,
    );
  }
}
