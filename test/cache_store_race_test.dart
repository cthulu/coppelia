import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:coppelia/models/media_item.dart';
import 'package:coppelia/services/cache_store.dart';

class _CacheManager extends Mock implements CacheManager {}

class _Loopback extends HttpOverrides {}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final Directory root;
  @override
  Future<String?> getTemporaryPath() async => root.path;
  @override
  Future<String?> getApplicationSupportPath() async => root.path;
}

MediaItem _track(String id, {String host = 'https://example.com'}) => MediaItem(
      id: id,
      title: id,
      album: 'Album',
      artists: const ['Artist'],
      duration: const Duration(seconds: 1),
      imageUrl: null,
      streamUrl: '$host/Audio/$id/universal',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Directory.systemTemp.createTempSync('coppelia_cache_races_');
  PathProviderPlatform.instance = _Paths(root);
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() async {
    if (Platform.isLinux || Platform.isWindows) {
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    await root.delete(recursive: true);
  });

  test('concurrent pins retain both pins and their metadata', () async {
    final cache = CacheStore()..activateScope('server');
    await Future.wait([
      cache.setPinnedAudioItem(_track('a'), true),
      cache.setPinnedAudioItem(_track('b'), true),
    ]);
    expect(await cache.loadPinnedAudio(), {'server:audio:a', 'server:audio:b'});
    expect((await cache.loadPinnedAudioItems()).map((t) => t.id),
        unorderedEquals(['a', 'b']));
    await Future.wait([
      cache.setPinnedAudio(_track('a').streamUrl, false),
      cache.setPinnedAudioItem(_track('c'), true),
    ]);
    expect(await cache.loadPinnedAudio(), {'server:audio:b', 'server:audio:c'});
    expect((await cache.loadPinnedAudioItems()).map((t) => t.id),
        unorderedEquals(['b', 'c']));
  });

  test('concurrent whole-library pins retain all updates', () async {
    final cache = CacheStore()..activateScope('server');
    await Future.wait([
      cache.setWholeLibraryPinnedAudio(_track('a').streamUrl, true),
      cache.setWholeLibraryPinnedAudio(_track('b').streamUrl, true),
    ]);
    expect(await cache.loadWholeLibraryPinnedAudio(),
        {'server:audio:a', 'server:audio:b'});
  });

  test('queued reads keep their server and explicit legacy scope', () async {
    final cache = CacheStore();
    await cache.saveAlbumTracks('album', [_track('legacy')]);
    cache.activateScope('A');
    await cache.saveAlbumTracks('album', [_track('a')]);
    cache.activateScope('B');
    await cache.saveAlbumTracks('album', [_track('b')]);
    cache.activateScope('A');
    final pending = cache.loadAlbumTracks('album');
    cache.activateScope('B');
    expect((await pending).single.id, 'a');
    cache.activateScope(null);
    final legacy = cache.loadAlbumTracks('album');
    final pin = cache.setPinnedAudioItem(_track('legacy'), true);
    cache.activateScope('B');
    expect((await legacy).single.id, 'legacy');
    await pin;
    expect(await cache.loadPinnedAudio(), isEmpty);
    cache.activateScope(null);
    expect(await cache.loadPinnedAudio(), {_track('legacy').streamUrl});
  });

  test('inventory pruning cannot overwrite a concurrent cache touch', () async {
    final manager = _CacheManager();
    final cache = CacheStore(audioCache: manager)..activateScope('server');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        'cached_audio_entries.server',
        jsonEncode({
          'server:audio:missing': {'title': 'Missing'},
        }));
    final file =
        await Config('cache-race-files').fileSystem.createFile('present');
    await file.writeAsString('audio');
    final started = Completer<void>();
    final release = Completer<FileInfo?>();
    when(() => manager.getFileFromCache('server:audio:missing'))
        .thenAnswer((_) {
      if (!started.isCompleted) started.complete();
      return release.future;
    });
    when(() => manager.getFileFromCache('server:audio:present')).thenAnswer(
        (_) async => FileInfo(
            file,
            FileSource.Cache,
            DateTime.now().add(const Duration(days: 1)),
            _track('present').streamUrl));
    final scan = cache.loadCachedAudioEntries();
    await started.future;
    final touch = cache.touchCachedAudio(_track('present'));
    await Future<void>.delayed(Duration.zero);
    release.complete(null);
    await Future.wait([scan, touch]);
    expect((await cache.loadCachedAudioEntries()).map((e) => e.cacheKey),
        ['server:audio:present']);
  });

  test('failed deletion preserves metadata and does not block later operations',
      () async {
    final manager = _CacheManager();
    final cache = CacheStore(audioCache: manager)..activateScope('server');
    final file = await Config('cache-race-files')
        .fileSystem
        .createFile('delete-failure');
    await file.writeAsString('audio');
    when(() => manager.getFileFromCache(any())).thenAnswer((call) async =>
        await file.exists()
            ? FileInfo(
                file, FileSource.Cache, DateTime.now(), _track('a').streamUrl)
            : null);
    when(() => manager.removeFile(any()))
        .thenThrow(StateError('index unavailable'));
    await cache.touchCachedAudio(_track('a'));
    await cache.setPinnedAudioItem(_track('a'), true);
    await expectLater(cache.clearScope('server'), throwsStateError);
    expect(await cache.loadPinnedAudio(), {'server:audio:a'});
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('cached_audio_entries.server'),
        contains('server:audio:a'));
    when(() => manager.removeFile(any())).thenAnswer((_) async {});
    await cache.clearScope('server');
    expect(await cache.loadPinnedAudio(), isEmpty);
  });

  for (final action in ['scope', 'audio', 'track']) {
    test('$action cleanup rejects a late real HTTP download', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final started = Completer<void>();
        final release = Completer<void>();
        server.listen((request) async {
          started.complete();
          await release.future;
          request.response
            ..contentLength = 6
            ..add('audio!'.codeUnits);
          await request.response.close();
        });
        final item =
            _track('clear-$action', host: 'http://127.0.0.1:${server.port}');
        final cache = CacheStore()..activateScope('server-$action');
        final download = cache.downloadAudioWithProgress(item).toList();
        await started.future.timeout(const Duration(seconds: 5));
        switch (action) {
          case 'scope':
            await cache.clearScope('server-$action');
          case 'audio':
            await cache.clearAudioCache();
          case 'track':
            await cache
                .evictCachedAudio(cache.audioKeyForStreamUrl(item.streamUrl));
        }
        release.complete();
        await expectLater(download, throwsA(isA<CacheDownloadCancelled>()));
        expect(await cache.loadCachedAudioEntries(), isEmpty);
        expect(await cache.getCachedAudio(item), isNull);
      }, _Loopback());
    });
  }

  test('cleanup outlives the listener and a new request uses fresh audio',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      server.listen((request) async {
        requests++;
        final first = requests == 1;
        if (first) {
          started.complete();
          await release.future;
        }
        request.response
          ..contentLength = 6
          ..add((first ? 'stale!' : 'fresh!').codeUnits);
        await request.response.close();
      });
      final item = _track('replace', host: 'http://127.0.0.1:${server.port}');
      final cache = CacheStore()..activateScope('replace-server');
      final listener = cache.downloadAudioWithProgress(item).listen((_) {});
      await started.future.timeout(const Duration(seconds: 5));
      await listener.cancel();
      await cache.clearAudioCache();
      final replacement = cache.downloadAudioWithProgress(item).toList();
      release.complete();
      await replacement.timeout(const Duration(seconds: 5));
      expect(requests, 2);
      expect(
          await (await cache.getCachedAudio(item))!.readAsString(), 'fresh!');
      expect(await cache.loadCachedAudioEntries(), hasLength(1));
    }, _Loopback());
  });
  test(
      'bulk pinning preserves concurrent manual intent through whole-library undo',
      () async {
    final cache = CacheStore()..activateScope('bulk-pins');
    final tracks = List.generate(700, (index) => _track('bulk-$index'));
    await Future.wait([
      cache.updateOfflineSelection(tracks, pinned: true, wholeLibrary: true),
      cache.updateOfflineSelection([tracks.first], pinned: true),
    ]);
    expect(await cache.loadPinnedAudio(), hasLength(700));
    expect(await cache.loadWholeLibraryPinnedAudio(), hasLength(699));
    final removed = await cache.removeWholeLibrarySelection();
    expect(removed, hasLength(699));
    expect(await cache.loadPinnedAudio(),
        {cache.audioKeyForStreamUrl(tracks.first.streamUrl)});
    expect((await cache.loadPinnedAudioItems()).single.id, tracks.first.id);
  });

  test('pinning protects retained files from a temporary-cache clear',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response
          ..contentLength = 6
          ..add('audio!'.codeUnits);
        await request.response.close();
      });
      final item = _track('durable', host: 'http://127.0.0.1:${server.port}');
      final cache = CacheStore()..activateScope('durable-files');
      await cache.updateOfflineSelection([item], pinned: true);
      await cache.downloadAudioWithProgress(item).drain<void>();
      final file = (await cache.getCachedAudio(item))!;
      expect(file.path, contains('offline_audio'));
      await cache.clearAudioCache();
      final reopened = CacheStore()..activateScope('durable-files');
      expect(await (await reopened.getCachedAudio(item))!.readAsString(),
          'audio!');
      expect(requests, 1);
      await reopened.clearScope('durable-files');
      expect(await file.exists(), isFalse);
    }, _Loopback());
  });

  test('a queued offline request cannot start after its pin was removed',
      () async {
    final cache = CacheStore()..activateScope('removed-pin');
    final item = _track('removed');
    await cache.updateOfflineSelection([item], pinned: true);
    await cache.updateOfflineSelection([item], pinned: false);
    await expectLater(
        cache.downloadAudioWithProgress(item, requirePin: true).drain<void>(),
        throwsA(isA<CacheDownloadCancelled>()));
    expect(await cache.loadCachedAudioEntries(), isEmpty);
  });
}
