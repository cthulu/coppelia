import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bg;
import 'package:crypto/crypto.dart';
import 'package:file/local.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import '../models/download_task.dart';

/// A transport failure safe to show without exposing URLs or auth headers.
class AudioDownloadFailure implements Exception {
  const AudioDownloadFailure(this.message,
      {this.retryable = false, this.retryAfter, this.requiresSignIn = false});
  final String message;
  final bool retryable;
  final Duration? retryAfter;
  final bool requiresSignIn;
  @override
  String toString() => message;
}

/// A notification cancellation is kept separate from an app-requested pause.
class AudioDownloadStopped implements Exception {
  const AudioDownloadStopped();
}

class AudioDownloadState extends FileResponse {
  const AudioDownloadState(super.originalUrl, {this.running = false});
  final bool running;
}

String audioFileId(String key) => sha256.convert(utf8.encode(key)).toString();

Future<File> retainedAudioFile(String key) async {
  final root = await getApplicationSupportDirectory();
  final directory = Directory('${root.path}/offline_audio/${audioFileId(key)}');
  if (await directory.exists()) {
    await for (final entry in directory.list()) {
      if (entry is File &&
          RegExp(r'/audio\.[a-z0-9]+$')
              .hasMatch(entry.path.replaceAll('\\', '/'))) {
        return entry;
      }
    }
  }
  return File('${directory.path}/audio.bin');
}

/// The platform owns queued transfers; Dart only observes them while alive.
class BackgroundAudioDownloads {
  BackgroundAudioDownloads({bg.FileDownloader? downloader})
      : _downloader = downloader ?? bg.FileDownloader();

  static const _group = 'coppelia-audio';
  final bg.FileDownloader _downloader;
  final _listeners = <String, StreamController<bg.TaskUpdate>>{};
  final _records = <String, bg.TaskRecord>{};
  final _scopeRevisions = <String?, int>{};
  final _keyRevisions = <String, int>{};
  Future<void>? _ready;
  Future<void> _commands = Future.value();
  int _activationRevision = 0;

  Future<T> _command<T>(Future<T> Function() action) {
    final result = _commands.then((_) => action());
    _commands =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<File> _suspensionFile(String id) async {
    final root = await getApplicationSupportDirectory();
    return File('${root.path}/offline_downloads/$id.suspended');
  }

  Future<void> _markForResume(String id) async {
    final file = await _suspensionFile(id);
    await file.parent.create(recursive: true);
    await file.writeAsString('resume', flush: true);
  }

  /// A manual retry must outlive the previous native failure, even while paused.
  Future<void> prepareRetry(String key) async {
    await initialize();
    await _command(() => _markForResume(audioFileId(key)));
  }

  Future<void> initialize() => _ready ??= _initialize();

  Future<void> _initialize() async {
    final root = await getApplicationSupportDirectory();
    final partials = Directory('${root.path}/offline_partials');
    await partials.create(recursive: true);
    _downloader.registerCallbacks(
      group: _group,
      taskStatusCallback: _update,
      taskProgressCallback: _update,
    );
    await _downloader.configure(
      globalConfig: [
        (bg.Config.requestTimeout, const Duration(seconds: 30)),
        (bg.Config.holdingQueue, (2, 2, 2))
      ],
      androidConfig: [
        (bg.Config.runInForeground, true),
        (bg.Config.useCacheDir, bg.Config.never),
        (bg.Config.tempFilePath, partials.path)
      ],
      desktopConfig: [(bg.Config.tempFilePath, partials.path)],
      iOSConfig: [(bg.Config.excludeFromCloudBackup, true)],
    );
    _downloader.configureNotificationForGroup(
      _group,
      running: const bg.TaskNotification(
          'Downloading music', '{numFinished} of {numTotal} songs'),
      error: const bg.TaskNotification(
          'Some songs need attention', 'Open Downloads to retry'),
      progressBar: true,
      groupNotificationId: _group,
    );
    // Recovery is scoped by AppState. Never automatically resurrect user stops
    // or transfers from an inactive server with the plugin's global helper.
    await _downloader.start(
        doRescheduleKilledTasks: false, markDownloadedComplete: false);
    for (final record in await _downloader.database.allRecords(group: _group)) {
      _records.putIfAbsent(record.taskId, () => record);
    }
    if ((await _downloader.allTasks(group: _group)).isEmpty) {
      await for (final file in partials.list()) {
        if (file is File) await file.delete();
      }
    }
  }

  void _update(bg.TaskUpdate update) {
    final previous = _records[update.task.taskId];
    if (previous != null &&
        previous.task.creationTime.millisecondsSinceEpoch >
            update.task.creationTime.millisecondsSinceEpoch) {
      return;
    }
    if (update is bg.TaskStatusUpdate) {
      _records[update.task.taskId] = bg.TaskRecord(
          update.task,
          update.status,
          previous?.progress ?? 0,
          previous?.expectedFileSize ?? -1,
          update.exception);
    }
    _listeners[update.task.taskId]?.add(update);
  }

  Future<void> requestNotifications() async {
    await initialize();
    if (await _downloader.permissions.status(bg.PermissionType.notifications) !=
        bg.PermissionStatus.granted) {
      await _downloader.permissions.request(bg.PermissionType.notifications);
    }
  }

  Future<void> activateScope(String? scope, {required bool paused}) async {
    final revision = ++_activationRevision;
    await initialize();
    final scopes = _records.values
        .map((record) => (jsonDecode(record.task.metaData)
            as Map<String, dynamic>)['scope'] as String?)
        .toSet();
    for (final storedScope in scopes) {
      if (revision != _activationRevision) return;
      if (storedScope != scope || paused) await cancel(scope: storedScope);
    }
  }

  Future<Set<String>> keysForScope(String? scope) async {
    await initialize();
    return _records.values
        .map((record) =>
            jsonDecode(record.task.metaData) as Map<String, dynamic>)
        .where((metadata) => metadata['scope'] == scope)
        .map((metadata) => metadata['key'] as String)
        .toSet();
  }

  Stream<FileResponse> download(
    String key,
    String url, {
    required String? scope,
    required String title,
    Map<String, String>? headers,
    bool requiresWifi = false,
    bool userInitiated = false,
    Map<String, dynamic>? mediaItem,
    DateTime? creationTime,
  }) =>
      _download(key, url,
          scope: scope,
          title: title,
          headers: headers,
          requiresWifi: requiresWifi,
          userInitiated: userInitiated,
          mediaItem: mediaItem,
          creationTime: creationTime ?? DateTime.now(),
          scopeRevision: _scopeRevisions[scope] ?? 0,
          keyRevision: _keyRevisions[key] ?? 0);

  Stream<FileResponse> _download(
    String key,
    String url, {
    required String? scope,
    required String title,
    Map<String, String>? headers,
    required bool requiresWifi,
    required bool userInitiated,
    required int scopeRevision,
    required int keyRevision,
    Map<String, dynamic>? mediaItem,
    required DateTime creationTime,
  }) async* {
    bool canceled() =>
        scopeRevision != (_scopeRevisions[scope] ?? 0) ||
        keyRevision != (_keyRevisions[key] ?? 0);
    await initialize();
    if (canceled()) throw const AudioDownloadStopped();
    final id = audioFileId(key);
    final events = StreamController<bg.TaskUpdate>();
    _listeners[id] = events;
    bg.Task? activeTask;
    try {
      await _command(() async {
        var existing = await _downloader.taskForId(id);
        if (canceled()) throw const AudioDownloadStopped();
        if (existing != null &&
            (existing.url != url ||
                !mapEquals(existing.headers, headers ?? {}) ||
                existing.requiresWiFi != requiresWifi)) {
          await _downloader.cancelTasksWithIds([id]);
          existing = null;
        }
        if (existing == null) {
          final completed = await completedFile(key);
          if (completed != null) {
            activeTask = _records[id]!.task;
            events
                .add(bg.TaskStatusUpdate(activeTask!, bg.TaskStatus.complete));
            return;
          }
          final task = bg.DownloadTask(
            taskId: id,
            url: url,
            headers: headers,
            creationTime: creationTime,
            baseDirectory: bg.BaseDirectory.applicationSupport,
            directory: 'offline_downloads',
            filename: '$id.${DateTime.now().microsecondsSinceEpoch}.audio',
            group: _group,
            displayName: title,
            metaData:
                jsonEncode({'scope': scope, 'key': key, 'item': mediaItem}),
            requiresWiFi: requiresWifi,
            priority: userInitiated ? 0 : 5,
            updates: bg.Updates.statusAndProgress,
          );
          activeTask = task;
          // Track before enqueue, closing the process-death gap between the
          // native queue accepting work and its first status callback.
          final record = bg.TaskRecord(task, bg.TaskStatus.enqueued, 0, -1);
          _records[id] = record;
          await _downloader.database.updateRecord(record);
          final suspension = await _suspensionFile(id);
          if (await suspension.exists()) await suspension.delete();
          if (canceled()) throw const AudioDownloadStopped();
          if (!await _downloader.enqueue(task)) {
            _records.remove(id);
            await _downloader.database.deleteRecordWithId(id);
            throw const AudioDownloadFailure('Could not start download.',
                retryable: true);
          }
          if (canceled()) {
            await _downloader.cancelTasksWithIds([id]);
            throw const AudioDownloadStopped();
          }
        } else {
          activeTask = existing;
        }
      });
      await for (final event in events.stream) {
        if (event.task.creationTime.millisecondsSinceEpoch !=
            activeTask?.creationTime.millisecondsSinceEpoch) {
          continue;
        }
        if (event is bg.TaskProgressUpdate && event.progress >= 0) {
          final size = event.expectedFileSize;
          yield DownloadProgress(url, size > 0 ? size : null,
              size > 0 ? (size * event.progress).round() : 0);
        } else if (event is bg.TaskStatusUpdate) {
          switch (event.status) {
            case bg.TaskStatus.complete:
              final file =
                  const LocalFileSystem().file(await event.task.filePath());
              if (!await file.exists()) {
                throw const AudioDownloadFailure('Downloaded file is missing.',
                    retryable: true);
              }
              yield FileInfo(file, FileSource.Online, DateTime(2100), url);
              return;
            case bg.TaskStatus.canceled:
            case bg.TaskStatus.paused:
              throw const AudioDownloadStopped();
            case bg.TaskStatus.failed:
            case bg.TaskStatus.notFound:
              throw failureFor(event);
            default:
              yield AudioDownloadState(url,
                  running: event.status == bg.TaskStatus.running);
          }
        }
      }
    } finally {
      if (identical(_listeners[id], events)) _listeners.remove(id);
      // Enqueue can fail before events.stream is listened to; close must not
      // wait for a subscriber that will never exist.
      unawaited(events.close());
    }
  }

  static AudioDownloadFailure failureFor(bg.TaskStatusUpdate update) {
    final error = update.exception;
    final code = update.responseStatusCode ??
        (error is bg.TaskHttpException ? error.httpResponseCode : null);
    final transient = error is bg.TaskConnectionException ||
        code == 408 ||
        code == 429 ||
        (code != null && code >= 500 && code <= 599);
    final retryHeader = update.responseHeaders?['retry-after'];
    final seconds = int.tryParse(retryHeader ?? '');
    Duration? retryAfter;
    if (seconds != null && seconds >= 0) {
      retryAfter = Duration(seconds: seconds);
    } else if (retryHeader != null) {
      try {
        retryAfter = HttpDate.parse(retryHeader).difference(DateTime.now());
      } catch (_) {}
    }
    final message = switch (code) {
      401 => 'Sign in again to download this song.',
      403 =>
        'The server denied access to this song. Check your account permissions.',
      404 => 'This song is no longer on the server.',
      _ when error is bg.TaskFileSystemException =>
        'Could not save the song. Check available storage.',
      _ when transient => 'Connection interrupted. Retrying shortly.',
      _ => 'Download failed. Retry from Downloads.',
    };
    return AudioDownloadFailure(message,
        retryable: transient,
        retryAfter: retryAfter,
        requiresSignIn: code == 401);
  }

  Future<void> cancel({String? key, Set<String>? keys, String? scope}) async {
    final selected = keys ?? (key == null ? null : {key});
    if (selected == null) {
      _scopeRevisions[scope] = (_scopeRevisions[scope] ?? 0) + 1;
    } else {
      for (final key in selected) {
        _keyRevisions[key] = (_keyRevisions[key] ?? 0) + 1;
      }
    }
    await initialize();
    await _command(() async {
      final records = _records.values.toList();
      final ids = <String>[];
      for (final record in records) {
        final metadata =
            jsonDecode(record.task.metaData) as Map<String, dynamic>;
        if (metadata['scope'] == scope &&
            (selected == null || selected.contains(metadata['key']))) {
          if (record.status.isNotFinalState) {
            await _markForResume(record.taskId);
            ids.add(record.taskId);
          }
        }
      }
      if (ids.isEmpty) return;
      if (!await _downloader.cancelTasksWithIds(ids)) {
        throw const AudioDownloadFailure(
            'Could not stop downloads. Try again.');
      }
      for (final id in ids) {
        final listener = _listeners[id];
        if (listener != null && !listener.isClosed) {
          listener.addError(const AudioDownloadStopped());
        }
      }
    });
  }

  Future<FileInfo?> completedFile(String key) async {
    await initialize();
    final record = _records[audioFileId(key)];
    if (record?.status != bg.TaskStatus.complete) return null;
    final file = const LocalFileSystem().file(await record!.task.filePath());
    if (!await file.exists()) return null;
    return FileInfo(file, FileSource.Cache, DateTime(2100), record.task.url);
  }

  Future<DownloadTask> restore(DownloadTask task, String key,
      {Map<String, String>? headers}) async {
    await initialize();
    final record = _records[audioFileId(key)];
    if (record == null) return task;
    if (await (await _suspensionFile(record.taskId)).exists()) {
      return task.status == DownloadStatus.failed ||
              task.status == DownloadStatus.waitingForSignIn ||
              task.status == DownloadStatus.stopped
          ? task.reset()
          : task;
    }
    if (record.status == bg.TaskStatus.canceled ||
        record.status == bg.TaskStatus.paused) {
      return task.copyWith(status: DownloadStatus.stopped);
    }
    if (record.status == bg.TaskStatus.failed ||
        record.status == bg.TaskStatus.notFound) {
      final error = record.exception;
      if (error is bg.TaskHttpException &&
          error.httpResponseCode == 401 &&
          headers != null &&
          !mapEquals(record.task.headers, headers)) {
        return task.reset(userInitiated: task.userInitiated);
      }
      final failure = failureFor(
          bg.TaskStatusUpdate(record.task, record.status, record.exception));
      return task.copyWith(
          status: failure.requiresSignIn
              ? DownloadStatus.waitingForSignIn
              : failure.retryable && task.attempts < 5
                  ? DownloadStatus.waitingToRetry
                  : DownloadStatus.failed,
          retryableFailure: failure.retryable,
          errorMessage: failure.message);
    }
    return task;
  }

  Future<void> forget(String key) async {
    await initialize();
    final id = audioFileId(key);
    final record = _records.remove(id);
    if (record != null) {
      final file = File(await record.task.filePath());
      if (await file.exists()) await file.delete();
      await _downloader.database.deleteRecordWithId(id);
    }
    final root = await getApplicationSupportDirectory();
    final staging = Directory('${root.path}/offline_downloads');
    if (await staging.exists()) {
      await for (final file in staging.list()) {
        if (file is File && file.uri.pathSegments.last.startsWith('$id.')) {
          await file.delete();
        }
      }
    }
  }

  Future<Map<String, Map<String, dynamic>>> completedMetadata(
      String? scope) async {
    await initialize();
    final items = <String, Map<String, dynamic>>{};
    for (final record in _records.values) {
      if (record.status != bg.TaskStatus.complete) continue;
      final metadata = jsonDecode(record.task.metaData) as Map<String, dynamic>;
      if (metadata['scope'] == scope && metadata['item'] is Map) {
        items[metadata['key'] as String] =
            Map<String, dynamic>.from(metadata['item'] as Map);
      }
    }
    return items;
  }
}
