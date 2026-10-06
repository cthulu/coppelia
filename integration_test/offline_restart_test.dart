import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:background_downloader/background_downloader.dart' as bg;

import 'package:coppelia/models/download_task.dart';
import 'package:coppelia/models/media_item.dart';
import 'package:coppelia/services/background_audio_downloads.dart';
import 'package:coppelia/services/cache_store.dart';

// Run with DOWNLOAD_RESTART_PHASE=seed, terminate the process after
// RESTART_READY, then run with phase=recover against the same local HTTP server.
// DOWNLOAD_TEST_ORIGIN must be reachable from the device (e.g. adb reverse).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const phase = String.fromEnvironment('DOWNLOAD_RESTART_PHASE');
  const origin = String.fromEnvironment('DOWNLOAD_TEST_ORIGIN');
  testWidgets('restores a persisted native batch after process termination',
      (tester) async {
    final worker = BackgroundAudioDownloads();
    final cache = CacheStore(backgroundDownloads: worker)
      ..activateScope('integration-restart');
    if (phase == 'seed') {
      await cache.clearScope('integration-restart');
      final tracks = List.generate(
          25,
          (index) => MediaItem(
              id: 'restart-$index',
              title: 'Song $index',
              album: 'Restart',
              artists: const [],
              duration: Duration.zero,
              imageUrl: null,
              streamUrl: '$origin/Audio/restart-$index/universal'));
      await cache.updateOfflineSelection(tracks, pinned: true);
      await cache.saveDownloadQueue(tracks
          .map((track) => DownloadTask(
              track: track,
              status: DownloadStatus.queued,
              queuedAt: DateTime.now(),
              userInitiated: true))
          .toList());
      for (final track in tracks.take(5)) {
        await cache
            .downloadAudioWithProgress(track, userInitiated: true)
            .drain<void>();
      }
      for (final track in tracks.skip(5)) {
        unawaited(cache
            .downloadAudioWithProgress(track, userInitiated: true)
            .drain<void>());
      }
      while (
          (await bg.FileDownloader().allTasks(group: 'coppelia-audio')).length <
              10) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      // ignore: avoid_print
      print('RESTART_READY');
      await Completer<void>().future;
    } else {
      final queue = await cache.loadDownloadQueue();
      expect(queue, hasLength(25));
      for (final task in queue.take(5)) {
        expect(await cache.isAudioCached(task.track), isTrue);
      }
      for (final task in queue) {
        if (await cache.isAudioCached(task.track)) continue;
        await cache
            .downloadAudioWithProgress(task.track, userInitiated: true)
            .drain<void>();
      }
      expect(await cache.loadCachedAudioEntries(), hasLength(25));
      await cache.clearScope('integration-restart');
    }
  },
      skip: phase.isEmpty || origin.isEmpty,
      timeout: const Timeout(Duration(minutes: 3)));
}
