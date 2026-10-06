import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:coppelia/models/media_item.dart';
import 'package:coppelia/services/background_audio_downloads.dart';
import 'package:coppelia/services/cache_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'native transfers retain files, recover completion, and cancel HTTP',
      (tester) async {
    final worker = BackgroundAudioDownloads();
    final cache = CacheStore(backgroundDownloads: worker)
      ..activateScope('integration-downloads');
    await cache.clearScope('integration-downloads');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final slowStarted = Completer<void>();
    final release = Completer<void>();
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (request.uri.path.contains('slow')) {
        slowStarted.complete();
        await release.future;
      }
      request.response
        ..contentLength = 5
        ..add([1, 2, 3, 4, 5]);
      try {
        await request.response.close();
      } catch (_) {}
    });
    MediaItem track(String id) => MediaItem(
        id: id,
        title: id,
        album: 'Test',
        artists: const [],
        duration: Duration.zero,
        imageUrl: null,
        streamUrl: 'http://127.0.0.1:${server.port}/Audio/$id/universal');
    try {
      final tracks = [track('one'), track('two')];
      await cache.updateOfflineSelection(tracks, pinned: true);
      await Future.wait(tracks.map((item) => cache
          .downloadAudioWithProgress(item, userInitiated: true)
          .drain<void>())).timeout(const Duration(seconds: 60));
      expect(requests, 2);
      for (final item in tracks) {
        expect(await (await cache.getCachedAudio(item))!.readAsBytes(),
            [1, 2, 3, 4, 5]);
      }
      await cache.clearAudioCache();
      expect((await cache.loadCachedAudioEntries()).length, 2);

      // Recover a native completion whose Dart cache-index write never ran.
      final lost = track('lost-index');
      final key = cache.audioKeyForStreamUrl(lost.streamUrl);
      await cache.updateOfflineSelection([lost], pinned: true);
      await worker
          .download(key, lost.streamUrl,
              scope: 'integration-downloads',
              title: lost.title,
              userInitiated: true)
          .drain<void>();
      final fresh = CacheStore(backgroundDownloads: worker)
        ..activateScope('integration-downloads');
      expect(await fresh.isAudioCached(lost), isTrue);
      expect((await fresh.loadCachedAudioEntries()).length, 3);
      expect(requests, 3);

      final slow = track('slow');
      await cache.updateOfflineSelection([slow], pinned: true);
      final transfer = cache.downloadAudioWithProgress(slow).drain<void>();
      final canceled =
          expectLater(transfer, throwsA(isA<CacheDownloadCancelled>()));
      await slowStarted.future.timeout(const Duration(seconds: 30));
      await cache
          .cancelDownloads(streamUrl: slow.streamUrl)
          .timeout(const Duration(seconds: 10));
      await canceled;
      release.complete();
      expect(await cache.isAudioCached(slow), isFalse);
    } finally {
      if (!release.isCompleted) release.complete();
      await cache.clearScope('integration-downloads');
      await server.close(force: true);
      await bg.FileDownloader()
          .database
          .deleteAllRecords(group: 'coppelia-audio');
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove('audio_download_queue.integration-downloads');
    }
  });
  testWidgets('a 700-song batch continues with the screen off', (tester) async {
    final worker = BackgroundAudioDownloads();
    final cache = CacheStore(backgroundDownloads: worker)
      ..activateScope('integration-batch');
    await cache.clearScope('integration-batch');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final started = Completer<void>();
    server.listen((request) async {
      requests++;
      if (!started.isCompleted) started.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.response
        ..contentLength = 16
        ..add(List.filled(16, 7));
      await request.response.close();
    });
    final tracks = List.generate(
        700,
        (index) => MediaItem(
            id: 'batch-$index',
            title: 'Song $index',
            album: 'Batch',
            artists: const [],
            duration: Duration.zero,
            imageUrl: null,
            streamUrl:
                'http://127.0.0.1:${server.port}/Audio/batch-$index/universal'));
    try {
      await cache.updateOfflineSelection(tracks,
          pinned: true, wholeLibrary: true);
      final transfers = Future.wait(tracks.map((item) => cache
          .downloadAudioWithProgress(item, userInitiated: true)
          .drain<void>()));
      await started.future;
      // The test runner switches off the emulator display after this marker.
      // ignore: avoid_print
      print('BACKGROUND_BATCH_READY');
      await transfers.timeout(const Duration(minutes: 5));
      expect(requests, 700);
      expect(await cache.loadCachedAudioEntries(), hasLength(700));
      await cache.clearAudioCache();
      expect(await cache.loadCachedAudioEntries(), hasLength(700));
    } finally {
      await cache.clearScope('integration-batch');
      await server.close(force: true);
    }
  });

  // The runner disables Wi-Fi before this case and reenables it at the marker.
  testWidgets('Wi-Fi downloads wait and resume when connectivity returns',
      (tester) async {
    final worker = BackgroundAudioDownloads();
    final cache = CacheStore(backgroundDownloads: worker)
      ..activateScope('integration-wifi');
    await cache.clearScope('integration-wifi');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response
        ..contentLength = 1
        ..add([7]);
      await request.response.close();
    });
    final track = MediaItem(
        id: 'wifi',
        title: 'Wi-Fi',
        album: 'Test',
        artists: const [],
        duration: Duration.zero,
        imageUrl: null,
        streamUrl: 'http://127.0.0.1:${server.port}/Audio/wifi/universal');
    try {
      await cache.updateOfflineSelection([track], pinned: true);
      final transfer = cache
          .downloadAudioWithProgress(track, requiresWifi: true)
          .drain<void>();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(requests, 0);
      // ignore: avoid_print
      print('WIFI_RECONNECT_READY');
      await transfer.timeout(const Duration(seconds: 45));
      expect(requests, 1);
      expect(await cache.isAudioCached(track), isTrue);
    } finally {
      await cache.clearScope('integration-wifi');
      await server.close(force: true);
    }
  }, skip: !const bool.fromEnvironment('DOWNLOAD_TEST_WIFI'));
}
