import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:coppelia/models/download_task.dart';
import 'package:coppelia/models/media_item.dart';
import 'package:coppelia/services/background_audio_downloads.dart';

class _Downloader extends Mock implements bg.FileDownloader {}

class _Database extends Mock implements bg.Database {}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;
  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Downloader native;
  late BackgroundAudioDownloads downloads;

  setUpAll(() {
    final task = bg.DownloadTask(url: 'https://example.com/audio');
    registerFallbackValue(task);
    registerFallbackValue(bg.TaskRecord(task, bg.TaskStatus.enqueued, 0, -1));
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('coppelia_native_downloads_');
    PathProviderPlatform.instance = _Paths(root);
    native = _Downloader();
    final database = _Database();
    when(() => native.database).thenReturn(database);
    when(() => native.registerCallbacks(
            group: any(named: 'group'),
            taskStatusCallback: any(named: 'taskStatusCallback'),
            taskProgressCallback: any(named: 'taskProgressCallback')))
        .thenReturn(native);
    when(() => native.configure(
        globalConfig: any(named: 'globalConfig'),
        androidConfig: any(named: 'androidConfig'),
        desktopConfig: any(named: 'desktopConfig'),
        iOSConfig: any(named: 'iOSConfig'))).thenAnswer((_) async => []);
    when(() => native.configureNotificationForGroup(any(),
            running: any(named: 'running'),
            error: any(named: 'error'),
            progressBar: true,
            groupNotificationId: any(named: 'groupNotificationId')))
        .thenReturn(native);
    when(() => native.start(
        doRescheduleKilledTasks: false,
        markDownloadedComplete: false)).thenAnswer((_) async {});
    when(() => native.allTasks(group: any(named: 'group')))
        .thenAnswer((_) async => []);
    when(() => database.allRecords(group: any(named: 'group')))
        .thenAnswer((_) async => []);
    when(() => database.updateRecord(any())).thenAnswer((_) async {});
    when(() => database.deleteRecordWithId(any())).thenAnswer((_) async {});
    when(() => native.taskForId(any())).thenAnswer((_) async => null);
    when(() => native.cancelTasksWithIds(any())).thenAnswer((_) async => true);
    downloads = BackgroundAudioDownloads(downloader: native);
  });

  tearDown(() => root.delete(recursive: true));

  test('native enqueue rejection reports a failure without hanging cleanup',
      () async {
    when(() => native.enqueue(any())).thenAnswer((_) async => false);
    await expectLater(
        downloads
            .download('server:audio:song', 'https://example.com/audio',
                scope: 'server', title: 'Song')
            .drain<void>()
            .timeout(const Duration(seconds: 1)),
        throwsA(isA<AudioDownloadFailure>()));
    await downloads.cancel(scope: 'server');
    verifyNever(() => native.cancelTasksWithIds(any()));
  });

  test('cancellation during native lookup finishes before a listener starts',
      () async {
    final started = Completer<void>();
    final lookup = Completer<bg.Task?>();
    when(() => native.taskForId(any())).thenAnswer((_) {
      started.complete();
      return lookup.future;
    });
    final result = expectLater(
        downloads
            .download('server:audio:song', 'https://example.com/audio',
                scope: 'server', title: 'Song')
            .drain<void>()
            .timeout(const Duration(seconds: 1)),
        throwsA(isA<AudioDownloadStopped>()));
    await started.future;
    final cancel = downloads.cancel(scope: 'server');
    lookup.complete(null);
    await cancel;
    await result;
    verifyNever(() => native.enqueue(any()));
  });

  for (final status in [bg.TaskStatus.canceled, bg.TaskStatus.failed]) {
    test('a manual retry survives restart over a native $status record',
        () async {
      const key = 'server:audio:song';
      const track = MediaItem(
          id: 'song',
          title: 'Song',
          album: 'Album',
          artists: [],
          duration: Duration.zero,
          imageUrl: null,
          streamUrl: 'https://example.com/audio');
      final nativeTask =
          bg.DownloadTask(taskId: audioFileId(key), url: track.streamUrl);
      final database = native.database;
      when(() => database.allRecords(group: any(named: 'group')))
          .thenAnswer((_) async => [bg.TaskRecord(nativeTask, status, 0, -1)]);
      final saved = DownloadTask(
          track: track,
          status: status == bg.TaskStatus.canceled
              ? DownloadStatus.stopped
              : DownloadStatus.failed,
          queuedAt: DateTime(2026));
      expect((await downloads.restore(saved, key)).status, saved.status);
      await downloads.prepareRetry(key);
      final relaunched = BackgroundAudioDownloads(downloader: native);
      expect(
          (await relaunched.restore(saved, key)).status, DownloadStatus.queued);
    });
  }

  test(
      'restored unauthorized downloads wait for sign-in and accept new credentials',
      () async {
    const key = 'server:audio:auth';
    const oldHeaders = {'Authorization': 'old-token'};
    final nativeTask = bg.DownloadTask(
        taskId: audioFileId(key),
        url: 'https://example.com/audio',
        headers: oldHeaders);
    final database = native.database;
    when(() => database.allRecords(group: any(named: 'group')))
        .thenAnswer((_) async => [
              bg.TaskRecord(nativeTask, bg.TaskStatus.failed, 0, -1,
                  bg.TaskHttpException('unauthorized', 401)),
            ]);
    final task = DownloadTask(
        track: const MediaItem(
            id: 'auth',
            title: 'Auth',
            album: 'Album',
            artists: [],
            duration: Duration.zero,
            imageUrl: null,
            streamUrl: 'https://example.com/audio'),
        status: DownloadStatus.queued,
        queuedAt: DateTime(2026),
        userInitiated: true,
        requiresWifi: true);
    final blocked = await downloads.restore(task, key, headers: oldHeaders);
    expect(blocked.status, DownloadStatus.waitingForSignIn);
    final resumed = await downloads
        .restore(blocked, key, headers: {'Authorization': 'new-token'});
    expect(resumed.status, DownloadStatus.queued);
    expect(resumed.requiresWifi, isTrue);
    expect(resumed.userInitiated, isTrue);
  });
}
