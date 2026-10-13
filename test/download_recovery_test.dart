import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:flutter_test/flutter_test.dart';
import 'package:coppelia/models/download_task.dart';
import 'package:coppelia/models/media_item.dart';
import 'package:coppelia/services/background_audio_downloads.dart';

void main() {
  test('sign-in recovery is offered for 401, not permission denial', () {
    final task = bg.DownloadTask(url: 'https://example.com/audio');
    final unauthorized = BackgroundAudioDownloads.failureFor(
        bg.TaskStatusUpdate(task, bg.TaskStatus.failed,
            bg.TaskHttpException('unauthorized', 401)));
    final forbidden = BackgroundAudioDownloads.failureFor(bg.TaskStatusUpdate(
        task, bg.TaskStatus.failed, bg.TaskHttpException('forbidden', 403)));
    expect(unauthorized.requiresSignIn, isTrue);
    expect(forbidden.requiresSignIn, isFalse);
    expect(forbidden.message, contains('permissions'));
  });
  test('only connection failures and temporary HTTP responses retry', () {
    final task = bg.DownloadTask(url: 'https://example.com/audio');
    for (final code in [401, 403, 404, 410]) {
      expect(
          BackgroundAudioDownloads.failureFor(bg.TaskStatusUpdate(
                  task,
                  bg.TaskStatus.failed,
                  bg.TaskHttpException('secret server response', code)))
              .retryable,
          isFalse);
    }
    for (final code in [408, 429, 500, 502, 503, 504]) {
      final failure = BackgroundAudioDownloads.failureFor(bg.TaskStatusUpdate(
          task,
          bg.TaskStatus.failed,
          bg.TaskHttpException('secret server response', code),
          null,
          {'retry-after': '12'}));
      expect(failure.retryable, isTrue);
      expect(failure.retryAfter, const Duration(seconds: 12));
      expect(failure.message, isNot(contains('secret')));
    }
    expect(
        BackgroundAudioDownloads.failureFor(bg.TaskStatusUpdate(task,
                bg.TaskStatus.failed, bg.TaskFileSystemException('disk full')))
            .retryable,
        isFalse);
    expect(
        BackgroundAudioDownloads.failureFor(bg.TaskStatusUpdate(task,
                bg.TaskStatus.failed, bg.TaskConnectionException('timeout')))
            .retryable,
        isTrue);
  });

  test(
      'queue persistence preserves order, policy, and retry time; reset clears failures',
      () {
    const track = MediaItem(
        id: 'song',
        title: 'Song',
        album: 'Album',
        artists: [],
        duration: Duration.zero,
        imageUrl: null,
        streamUrl: 'https://example.com/Audio/song/universal');
    final task = DownloadTask(
        track: track,
        status: DownloadStatus.waitingToRetry,
        queuedAt: DateTime(2026),
        requiresWifi: true,
        attempts: 3,
        retryAt: DateTime(2026, 10),
        errorMessage: 'network',
        progress: 0.5,
        downloadedBytes: 1024,
        totalBytes: 2048);
    final restored = DownloadTask.fromJson(task.toJson());
    expect(restored.requiresWifi, isTrue);
    expect(restored.attempts, 3);
    expect(restored.retryAt, task.retryAt);
    expect(restored.queuedAt, task.queuedAt);
    final retry = task.reset();
    expect(retry.progress, isNull);
    expect(retry.errorMessage, isNull);
    expect(retry.downloadedBytes, isNull);
    expect(retry.totalBytes, isNull);
    expect(retry.retryAt, isNull);
    expect(retry.attempts, 0);
    expect(retry.requiresWifi, isTrue);
  });
}
