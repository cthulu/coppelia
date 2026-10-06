import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mime/mime.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/album.dart';
import '../models/download_task.dart';
import '../models/artist.dart';
import '../models/cached_audio_entry.dart';
import '../models/genre.dart';
import '../models/library_stats.dart';
import '../models/media_item.dart';
import '../models/playback_resume_state.dart';
import '../models/playlist.dart';
import 'log_service.dart';
import 'background_audio_downloads.dart';

/// A cache clear or eviction invalidated an in-flight download.
class CacheDownloadCancelled implements Exception {
  const CacheDownloadCancelled();
}

class CachedAudioFile extends FileInfo {
  CachedAudioFile(FileInfo source, this.bytes)
      : super(source.file, source.source, source.validTill, source.originalUrl);

  final int bytes;
}

/// Manages cached metadata and audio assets.
class CacheStore {
  /// Creates a cache manager instance.
  CacheStore({CacheManager? audioCache, this.backgroundDownloads})
      : _audioCache = audioCache ??
            CacheManager(
              Config(_audioCacheKey,
                  stalePeriod: const Duration(days: 3650),
                  maxNrOfCacheObjects: 20000),
            );

  /// Default cache size limit (500 MB).
  static const int defaultCacheMaxBytes = 500 * 1024 * 1024;

  static const _downloadQueueKey = 'audio_download_queue';
  static const _audioCacheKey = 'coppelia_audio_cache';
  static const _playlistsKey = 'cached_playlists';
  static const _tracksKey = 'cached_playlist_tracks';
  static const _featuredKey = 'cached_featured_tracks';
  static const _albumsKey = 'cached_albums';
  static const _recentlyAddedAlbumsKey = 'cached_recently_added_albums';
  static const _artistsKey = 'cached_artists';
  static const _genresKey = 'cached_genres';
  static const _albumTracksKey = 'cached_album_tracks';
  static const _artistTracksKey = 'cached_artist_tracks';
  static const _genreTracksKey = 'cached_genre_tracks';
  static const _favoriteAlbumsKey = 'cached_favorite_albums';
  static const _favoriteArtistsKey = 'cached_favorite_artists';
  static const _favoriteTracksKey = 'cached_favorite_tracks';
  static const _libraryTracksKey = 'cached_library_tracks';
  static const _recentTracksKey = 'cached_recent_tracks';
  static const _playHistoryKey = 'cached_play_history';
  static const _libraryStatsKey = 'cached_library_stats';
  static const _cachedAudioKey = 'cached_audio_entries';
  static const _cachedAudioLimitKey = 'cached_audio_limit_bytes';
  static const _pinnedAudioKey = 'cached_audio_pins';
  static const _pinnedAudioItemsKey = 'cached_audio_pin_items';
  static const _wholeLibraryPinnedAudioKey = 'cached_audio_whole_library_pins';
  static const _playbackResumeKey = 'cached_playback_resume';

  static const _legacyCacheKeyField = 'legacyCacheKey';

  static const _metadataKeys = <String>[
    _playlistsKey,
    _tracksKey,
    _featuredKey,
    _albumsKey,
    _recentlyAddedAlbumsKey,
    _artistsKey,
    _genresKey,
    _albumTracksKey,
    _artistTracksKey,
    _genreTracksKey,
    _favoriteAlbumsKey,
    _favoriteArtistsKey,
    _favoriteTracksKey,
    _libraryTracksKey,
    _recentTracksKey,
    _playHistoryKey,
    _libraryStatsKey,
    _playbackResumeKey,
  ];

  static const _profileKeys = <String>[
    ..._metadataKeys,
    _downloadQueueKey,
    _cachedAudioKey,
    _pinnedAudioKey,
    _pinnedAudioItemsKey,
    _wholeLibraryPinnedAudioKey,
  ];

  String? _scope;

  final CacheManager _audioCache;
  final BackgroundAudioDownloads? backgroundDownloads;
  bool localPlaybackOnly = false;

  Future<void> cancelDownloads({String? streamUrl}) async {
    final scope = _scope;
    final key =
        streamUrl == null ? null : _audioKeyForStreamUrl(streamUrl, scope);
    _invalidateDownloads(scope, cacheKey: key);
    final pending = _audioDownloads
        .where((download) =>
            download.scope == scope &&
            (key == null || download.cacheKey == key))
        .map((download) => download.finished.future)
        .toList();
    await backgroundDownloads?.cancel(scope: scope, key: key);
    if (backgroundDownloads != null) {
      await Future.wait(pending);
    }
  }

  Future<void> _pendingOperation = Future<void>.value();
  final Set<_AudioDownload> _audioDownloads = {};
  int _downloadOrder = 0;

  // Only storage work belongs here; network transfers run outside this queue.
  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _pendingOperation.then((_) => operation());
    _pendingOperation =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  void _invalidateDownloads(String? scope, {String? cacheKey}) {
    for (final download in _audioDownloads) {
      if (download.scope == scope &&
          (cacheKey == null || download.cacheKey == cacheKey)) {
        download.invalidated = true;
      }
    }
  }

  /// Activates the profile scope used for library and offline data.
  void activateScope(String? serverId) {
    if (_scope != serverId) {
      _invalidateDownloads(_scope);
    }
    _scope = serverId;
  }

  /// Moves legacy single-session cache data into a server-specific scope.
  Future<void> migrateLegacyData(String serverId) {
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      final legacyAudioEntries = _readJsonMap(
        preferences.getString(_cachedAudioKey),
      );
      final migratedAudioEntries = <String, dynamic>{};
      for (final entry in legacyAudioEntries.entries) {
        final payload = entry.value;
        if (payload is! Map) {
          continue;
        }
        final payloadMap = Map<String, dynamic>.from(payload);
        final mediaItem = payloadMap['mediaItem'];
        final itemId = mediaItem is Map<String, dynamic>
            ? mediaItem['id']?.toString()
            : _streamItemId(entry.key);
        if (itemId == null || itemId.isEmpty) {
          continue;
        }
        migratedAudioEntries['$serverId:audio:$itemId'] = {
          ...payloadMap,
          _legacyCacheKeyField: entry.key,
        };
      }

      for (final key in _profileKeys) {
        if (key == _cachedAudioKey) {
          continue;
        }
        final value = preferences.get(key);
        if (value != null) {
          await _copyPreferenceValue(
              preferences, _scopedKey(key, serverId), value);
        }
      }
      if (migratedAudioEntries.isNotEmpty) {
        await preferences.setString(
          _scopedKey(_cachedAudioKey, serverId),
          jsonEncode(migratedAudioEntries),
        );
      }
      final legacyPinned =
          _readJsonList(preferences.getString(_pinnedAudioKey));
      if (legacyPinned.isNotEmpty) {
        await preferences.setString(
          _scopedKey(_pinnedAudioKey, serverId),
          jsonEncode(
            legacyPinned
                .map((entry) =>
                    _audioKeyForStreamUrl(entry.toString(), serverId))
                .toSet()
                .toList(),
          ),
        );
      }
      final legacyPinnedItems = _readJsonMap(
        preferences.getString(_pinnedAudioItemsKey),
      );
      if (legacyPinnedItems.isNotEmpty) {
        final migratedPinnedItems = <String, dynamic>{};
        for (final entry in legacyPinnedItems.entries) {
          final item = entry.value;
          final itemId = item is Map<String, dynamic>
              ? item['id']?.toString()
              : _streamItemId(entry.key);
          if (itemId != null && itemId.isNotEmpty) {
            migratedPinnedItems['$serverId:audio:$itemId'] = item;
          }
        }
        await preferences.setString(
          _scopedKey(_pinnedAudioItemsKey, serverId),
          jsonEncode(migratedPinnedItems),
        );
      }
      final legacyWholeLibraryPins = _readJsonList(
        preferences.getString(_wholeLibraryPinnedAudioKey),
      );
      if (legacyWholeLibraryPins.isNotEmpty) {
        await preferences.setString(
          _scopedKey(_wholeLibraryPinnedAudioKey, serverId),
          jsonEncode(
            legacyWholeLibraryPins
                .map((entry) =>
                    _audioKeyForStreamUrl(entry.toString(), serverId))
                .toSet()
                .toList(),
          ),
        );
      }
      for (final key in _profileKeys) {
        await preferences.remove(key);
      }
    });
  }

  /// Deletes all local data belonging to one saved server.
  Future<void> clearScope(String serverId) {
    _invalidateDownloads(serverId);
    return _serialized(() async {
      await backgroundDownloads?.cancel(scope: serverId);
      await _clearAudioCacheForScope(serverId);
      final preferences = await SharedPreferences.getInstance();
      for (final key in _profileKeys) {
        await preferences.remove(_scopedKey(key, serverId));
      }
    });
  }

  /// Returns a stable cache identity for a stream in the active profile.
  String audioKeyForStreamUrl(String streamUrl) =>
      _audioKeyForStreamUrl(streamUrl, _scope);

  String _audioKeyForStreamUrl(String streamUrl, String? scope) {
    final itemId = _streamItemId(streamUrl);
    if (scope == null || itemId == null || itemId.isEmpty) {
      return streamUrl;
    }
    return '$scope:audio:$itemId';
  }

  String? _streamItemId(String streamUrl) {
    final uri = Uri.tryParse(streamUrl);
    if (uri == null) {
      return null;
    }
    final segments = uri.pathSegments;
    final index = segments.indexOf('Audio');
    if (index == -1 || index + 1 >= segments.length) {
      return null;
    }
    return segments[index + 1];
  }

  String _scopedKey(String key, String? scope) =>
      scope == null ? key : '$key.$scope';

  Map<String, dynamic> _readJsonMap(String? raw) {
    if (raw == null || raw.isEmpty) {
      return {};
    }
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  List<dynamic> _readJsonList(String? raw) {
    if (raw == null || raw.isEmpty) {
      return [];
    }
    try {
      return jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return [];
    }
  }

  Future<void> _copyPreferenceValue(
    SharedPreferences preferences,
    String key,
    Object value,
  ) async {
    if (value is String) {
      await preferences.setString(key, value);
    } else if (value is int) {
      await preferences.setInt(key, value);
    } else if (value is bool) {
      await preferences.setBool(key, value);
    } else if (value is double) {
      await preferences.setDouble(key, value);
    } else if (value is List<String>) {
      await preferences.setStringList(key, value);
    }
  }

  /// Persists playlists for offline use.
  Future<void> savePlaylists(List<Playlist> playlists) =>
      _saveList(_playlistsKey, playlists);

  /// Loads cached playlists, if any exist.
  Future<List<Playlist>> loadPlaylists() =>
      _loadList(_playlistsKey, Playlist.fromJson);

  /// Persists playlist tracks to the cache.
  Future<void> savePlaylistTracks(
    String playlistId,
    List<MediaItem> tracks,
  ) =>
      _saveTrackMap(_tracksKey, playlistId, tracks);

  /// Returns cached tracks for a playlist.
  Future<List<MediaItem>> loadPlaylistTracks(String playlistId) =>
      _loadTrackMap(_tracksKey, playlistId);

  /// Persists featured tracks for the home screen.
  Future<void> saveFeaturedTracks(List<MediaItem> tracks) =>
      _saveList(_featuredKey, tracks);

  /// Loads cached featured tracks.
  Future<List<MediaItem>> loadFeaturedTracks() =>
      _loadList(_featuredKey, MediaItem.fromJson);

  /// Persists albums for offline use.
  Future<void> saveAlbums(List<Album> albums) => _saveList(_albumsKey, albums);

  /// Loads cached albums.
  Future<List<Album>> loadAlbums() => _loadList(_albumsKey, Album.fromJson);

  /// Persists the newest albums shown on the Home screen.
  Future<void> saveRecentlyAddedAlbums(List<Album> albums) =>
      _saveList(_recentlyAddedAlbumsKey, albums);

  /// Loads the cached newest albums shown on the Home screen.
  Future<List<Album>> loadRecentlyAddedAlbums() =>
      _loadList(_recentlyAddedAlbumsKey, Album.fromJson);

  /// Persists artists for offline use.
  Future<void> saveArtists(List<Artist> artists) =>
      _saveList(_artistsKey, artists);

  /// Loads cached artists.
  Future<List<Artist>> loadArtists() => _loadList(_artistsKey, Artist.fromJson);

  /// Persists genres for offline use.
  Future<void> saveGenres(List<Genre> genres) => _saveList(_genresKey, genres);

  /// Loads cached genres.
  Future<List<Genre>> loadGenres() => _loadList(_genresKey, Genre.fromJson);

  /// Persists album tracks to the cache.
  Future<void> saveAlbumTracks(
    String albumId,
    List<MediaItem> tracks,
  ) =>
      _saveTrackMap(_albumTracksKey, albumId, tracks);

  /// Loads cached album tracks.
  Future<List<MediaItem>> loadAlbumTracks(String albumId) =>
      _loadTrackMap(_albumTracksKey, albumId);

  /// Persists artist tracks to the cache.
  Future<void> saveArtistTracks(
    String artistId,
    List<MediaItem> tracks,
  ) =>
      _saveTrackMap(_artistTracksKey, artistId, tracks);

  /// Loads cached artist tracks.
  Future<List<MediaItem>> loadArtistTracks(String artistId) =>
      _loadTrackMap(_artistTracksKey, artistId);

  /// Persists genre tracks to the cache.
  Future<void> saveGenreTracks(
    String genreId,
    List<MediaItem> tracks,
  ) =>
      _saveTrackMap(_genreTracksKey, genreId, tracks);

  /// Loads cached genre tracks.
  Future<List<MediaItem>> loadGenreTracks(String genreId) =>
      _loadTrackMap(_genreTracksKey, genreId);

  /// Persists favorite albums for quick access.
  Future<void> saveFavoriteAlbums(List<Album> albums) =>
      _saveList(_favoriteAlbumsKey, albums);

  /// Loads cached favorite albums.
  Future<List<Album>> loadFavoriteAlbums() =>
      _loadList(_favoriteAlbumsKey, Album.fromJson);

  /// Persists favorite artists.
  Future<void> saveFavoriteArtists(List<Artist> artists) =>
      _saveList(_favoriteArtistsKey, artists);

  /// Loads cached favorite artists.
  Future<List<Artist>> loadFavoriteArtists() =>
      _loadList(_favoriteArtistsKey, Artist.fromJson);

  /// Persists favorite tracks.
  Future<void> saveFavoriteTracks(List<MediaItem> tracks) =>
      _saveList(_favoriteTracksKey, tracks);

  /// Loads cached favorite tracks.
  Future<List<MediaItem>> loadFavoriteTracks() =>
      _loadList(_favoriteTracksKey, MediaItem.fromJson);

  /// Persists a complete library track snapshot for Smart List evaluation.
  Future<void> saveLibraryTracks(List<MediaItem> tracks) =>
      _saveList(_libraryTracksKey, tracks);

  /// Loads the cached complete library track snapshot.
  Future<List<MediaItem>> loadLibraryTracks() =>
      _loadList(_libraryTracksKey, MediaItem.fromJson);

  /// Persists recent tracks for the home shelf.
  Future<void> saveRecentTracks(List<MediaItem> tracks) =>
      _saveList(_recentTracksKey, tracks);

  /// Loads cached recent tracks.
  Future<List<MediaItem>> loadRecentTracks() =>
      _loadList(_recentTracksKey, MediaItem.fromJson);

  /// Persists playback history.
  Future<void> savePlayHistory(List<MediaItem> tracks) =>
      _saveList(_playHistoryKey, tracks);

  /// Persists the last known playback state for resume.
  Future<void> savePlaybackResumeState(PlaybackResumeState? state) {
    final storageKey = _scopedKey(_playbackResumeKey, _scope);
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      if (state == null) {
        await preferences.remove(storageKey);
      } else {
        await preferences.setString(storageKey, jsonEncode(state.toJson()));
      }
    });
  }

  /// Loads the last known playback state for resume.
  Future<PlaybackResumeState?> loadPlaybackResumeState() {
    final storageKey = _scopedKey(_playbackResumeKey, _scope);
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(storageKey);
      if (raw == null || raw.isEmpty) {
        return null;
      }
      return PlaybackResumeState.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    });
  }

  /// Loads cached playback history.
  Future<List<MediaItem>> loadPlayHistory() =>
      _loadList(_playHistoryKey, MediaItem.fromJson);

  /// Persists library statistics for the home screen.
  Future<void> saveLibraryStats(LibraryStats stats) {
    final scope = _scope;
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        _scopedKey(_libraryStatsKey, scope),
        jsonEncode(stats.toJson()),
      );
    });
  }

  /// Loads cached library stats.
  Future<LibraryStats?> loadLibraryStats() {
    final storageKey = _scopedKey(_libraryStatsKey, _scope);
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(storageKey);
      if (raw == null || raw.isEmpty) {
        return null;
      }
      return LibraryStats.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    });
  }

  /// Returns a cached audio file if present.
  Future<File?> getCachedAudio(MediaItem item, {bool touch = false}) {
    final scope = _scope;
    return _serialized(() async {
      final cached = await _getAudioCacheInfoForItem(item, scope: scope);
      if (touch && cached != null) {
        await _rememberCachedAudio(item, scope: scope);
      }
      return cached?.file;
    });
  }

  /// Returns true when the audio is cached on disk.
  Future<bool> isAudioCached(MediaItem item) {
    final scope = _scope;
    return _serialized(() async {
      final cached = await _getAudioCacheInfoForItem(item, scope: scope);
      return cached != null;
    });
  }

  Future<void> saveDownloadQueue(List<DownloadTask> tasks) =>
      _saveList(_downloadQueueKey, tasks.map((task) => task.toJson()).toList());

  Future<List<DownloadTask>> loadDownloadQueue() {
    final scope = _scope;
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      return _readJsonList(
              preferences.getString(_scopedKey(_downloadQueueKey, scope)))
          .map((value) =>
              DownloadTask.fromJson(Map<String, dynamic>.from(value as Map)))
          .toList();
    });
  }

  /// Downloads audio for offline-ready playback.
  Future<void> prefetchAudio(
    MediaItem item, {
    Map<String, String>? headers,
    bool requiresWifi = false,
  }) async {
    try {
      await downloadAudioWithProgress(item,
              headers: headers, requiresWifi: requiresWifi)
          .drain<void>();
    } on CacheDownloadCancelled {
      // Intentional cleanup is not a prefetch failure.
    } catch (error) {
      final log = await LogService.instance;
      await log.warning('prefetchAudio failed for "${item.title}": $error');
    }
  }

  /// Streams a download with progress updates and caches the result.
  Stream<FileResponse> downloadAudioWithProgress(
    MediaItem item, {
    Map<String, String>? headers,
    bool requiresWifi = false,
    bool userInitiated = false,
    bool requirePin = false,
  }) {
    final scope = _scope;
    final key = _audioKeyForStreamUrl(item.streamUrl, scope);
    final previous = _audioDownloads
        .where((download) => download.cacheKey == key)
        .map((download) => download.finished.future)
        .toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    _downloadOrder = now > _downloadOrder ? now : _downloadOrder + 1;
    final download = _AudioDownload(
        scope, key, DateTime.fromMillisecondsSinceEpoch(_downloadOrder));
    final controller = StreamController<FileResponse>();
    controller.onCancel = () {
      unawaited(controller.close());
    };
    _audioDownloads.add(download);
    unawaited(_downloadAudio(
        item,
        headers == null ? null : Map.of(headers),
        download,
        previous,
        controller,
        requiresWifi,
        userInitiated,
        requirePin));
    return controller.stream;
  }

  Future<void> _downloadAudio(
    MediaItem item,
    Map<String, String>? headers,
    _AudioDownload download,
    List<Future<void>> previous,
    StreamController<FileResponse> controller,
    bool requiresWifi,
    bool userInitiated,
    bool requirePin,
  ) async {
    try {
      // A new request must not join an invalidated cache-manager transfer.
      await Future.wait(previous);
      await _serialized(() async {});
      if (download.invalidated) throw const CacheDownloadCancelled();
      if (requirePin &&
          !(await _serialized(() => _loadPinnedAudio(scope: download.scope)))
              .contains(download.cacheKey)) {
        throw const CacheDownloadCancelled();
      }
      final retained = await _serialized(
          () => _getAudioCacheInfoForItem(item, scope: download.scope));
      if (download.invalidated) throw const CacheDownloadCancelled();
      if (retained != null) {
        if (!download.invalidated && !controller.isClosed) {
          controller.add(retained);
        }
        return;
      }
      final responses = backgroundDownloads?.download(
              download.cacheKey, item.streamUrl,
              scope: download.scope,
              title: item.title,
              headers: headers,
              mediaItem: item.toJson(),
              creationTime: download.createdAt,
              requiresWifi: requiresWifi,
              userInitiated: userInitiated) ??
          _audioCache.getFileStream(
            item.streamUrl,
            key: download.cacheKey,
            headers: headers,
            withProgress: true,
          );
      await for (final response in responses) {
        FileResponse result = response;
        if (response is FileInfo) {
          await _serialized(() async {
            if (download.invalidated) {
              await _deleteAudioFile(download.cacheKey);
              return;
            }
            final retained = await _retainAudio(download.cacheKey, response);
            result = CachedAudioFile(retained, await retained.file.length());
            await _rememberCachedAudio(item, scope: download.scope);
            // Pinned files do not consume the disposable cache budget.
            if (!(await _loadPinnedAudio(scope: download.scope))
                .contains(download.cacheKey)) {
              await _enforceCacheLimit(download.scope);
            }
          });
        }
        if (!download.invalidated && !controller.isClosed) {
          controller.add(result);
        }
      }
      if (download.invalidated) throw const CacheDownloadCancelled();
    } catch (error, stackTrace) {
      if (!controller.isClosed) {
        controller.addError(
            download.invalidated ? const CacheDownloadCancelled() : error,
            stackTrace);
      }
    } finally {
      _audioDownloads.remove(download);
      download.finished.complete();
      // Closing must not wait for a cancelled or paused UI subscription.
      unawaited(controller.close());
    }
  }

  /// Updates the LRU timestamp for a cached track.
  Future<void> touchCachedAudio(MediaItem item) {
    final scope = _scope;
    return _serialized(() async {
      final cached = await _getAudioCacheInfoForItem(item, scope: scope);
      if (cached == null) {
        return;
      }
      await _rememberCachedAudio(item, scope: scope);
    });
  }

  /// Prefetches the next track in the queue, when available.
  Future<void> prefetchNextFromQueue(
    List<MediaItem> queue,
    int currentIndex, {
    Map<String, String>? headers,
    bool requiresWifi = false,
  }) async {
    final scope = _scope;
    final nextIndex = currentIndex + 1;
    if (nextIndex < 0 || nextIndex >= queue.length) {
      return;
    }
    final next = queue[nextIndex];
    if (await isAudioCached(next)) {
      return;
    }
    if (_scope != scope) return;
    await prefetchAudio(next, headers: headers, requiresWifi: requiresWifi);
  }

  /// Handles cache updates when playback advances.
  Future<void> handlePlaybackAdvance(
    List<MediaItem> queue,
    int currentIndex, {
    Map<String, String>? headers,
    bool requiresWifi = false,
  }) async {
    if (currentIndex < 0 || currentIndex >= queue.length) {
      return;
    }
    final scope = _scope;
    final current = queue[currentIndex];
    await touchCachedAudio(current);
    if (_scope != scope) return;
    await prefetchNextFromQueue(queue, currentIndex,
        headers: headers, requiresWifi: requiresWifi);
  }

  /// Clears cached metadata for library lists and tracks.
  Future<void> clearMetadata() {
    final scope = _scope;
    return _serialized(() async {
      await _clearMetadataForScope(scope);
    });
  }

  Future<void> _clearMetadataForScope(String? scope) async {
    final preferences = await SharedPreferences.getInstance();
    for (final key in _metadataKeys) {
      await preferences.remove(_scopedKey(key, scope));
    }
  }

  /// Clears disposable audio while preserving offline selections and files.
  Future<void> clearAudioCache() {
    final scope = _scope;
    return _serialized(() async {
      final pinned = await _loadPinnedAudio(scope: scope);
      for (final download in _audioDownloads.toList()) {
        if (download.scope == scope && !pinned.contains(download.cacheKey)) {
          download.invalidated = true;
          await backgroundDownloads?.cancel(
              scope: scope, key: download.cacheKey);
        }
      }
      final entries = await _loadCachedAudioEntriesForScope(scope);
      final removed = <String>{};
      for (final entry in entries) {
        if (pinned.contains(entry.cacheKey)) continue;
        await _deleteAudioFile(entry.cacheKey,
            legacyCacheKey: entry.legacyCacheKey);
        removed.add(entry.cacheKey);
      }
      await _forgetCachedAudioEntries(removed, scope: scope);
    });
  }

  Future<void> _clearAudioCacheForScope(String? scope) async {
    final entries = await _loadCachedAudioEntriesForScope(scope);
    final keys = await _loadPinnedAudio(scope: scope);
    keys.addAll(await backgroundDownloads?.keysForScope(scope) ?? {});
    for (final entry in entries) {
      keys.remove(entry.cacheKey);
      await _deleteAudioFile(
        entry.cacheKey,
        legacyCacheKey: entry.legacyCacheKey,
      );
    }
    for (final key in keys) {
      await _deleteAudioFile(key);
    }
    await _saveCachedAudioEntries(const {}, scope: scope);
  }

  /// Returns the approximate size of cached media on disk.
  Future<int> getMediaCacheBytes() {
    final scope = _scope;
    return _serialized(() async {
      final entries = await _loadCachedAudioEntriesForScope(scope);
      return entries.fold<int>(0, (sum, entry) => sum + entry.bytes);
    });
  }

  /// Returns the total bytes used by pinned tracks.
  Future<int> getPinnedMediaBytes(Set<String> pinnedAudio) {
    final scope = _scope;
    return _serialized(() async {
      if (pinnedAudio.isEmpty) {
        return 0;
      }
      final entries = await _loadCachedAudioEntriesForScope(scope);
      return entries
          .where((entry) => pinnedAudio.contains(entry.cacheKey))
          .fold<int>(0, (sum, entry) => sum + entry.bytes);
    });
  }

  /// Loads the configured cache size limit.
  Future<int> loadCacheMaxBytes() async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getInt(_cachedAudioLimitKey);
    if (stored != null && stored >= 0) {
      return stored;
    }
    await preferences.setInt(_cachedAudioLimitKey, defaultCacheMaxBytes);
    return defaultCacheMaxBytes;
  }

  /// Saves the configured cache size limit.
  Future<void> saveCacheMaxBytes(int bytes) {
    final scope = _scope;
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_cachedAudioLimitKey, bytes);
      await _enforceCacheLimit(scope, maxBytes: bytes);
    });
  }

  /// Returns a list of cached audio entries with metadata.
  Future<List<CachedAudioEntry>> loadCachedAudioEntries() {
    final scope = _scope;
    return _serialized(() async {
      return _loadCachedAudioEntriesForScope(scope);
    });
  }

  Future<List<CachedAudioEntry>> _loadCachedAudioEntriesForScope(
    String? scope,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_scopedKey(_cachedAudioKey, scope));
    final decoded = _readJsonMap(raw);
    var recovered = false;
    final pinnedItems = _readJsonMap(
        preferences.getString(_scopedKey(_pinnedAudioItemsKey, scope)));
    final completed = await backgroundDownloads?.completedMetadata(scope) ?? {};
    pinnedItems.addAll(completed);
    for (final pin in pinnedItems.entries) {
      if (!decoded.containsKey(pin.key) &&
          await _getAudioCacheInfo(pin.key) != null) {
        final item = _mediaItemFromCachedPayload({'mediaItem': pin.value});
        if (item == null) continue;
        decoded[pin.key] = {
          'title': item.title,
          'album': item.album,
          'artists': item.artists,
          'mediaItem': item.toJson(),
          'cachedAt': DateTime.now().toIso8601String()
        };
        recovered = true;
      }
    }
    final entries = <CachedAudioEntry>[];
    final toRemove = <String>[];

    for (final entry in decoded.entries) {
      final value = entry.value is Map
          ? Map<String, dynamic>.from(entry.value as Map)
          : null;
      if (value == null) {
        toRemove.add(entry.key);
        continue;
      }
      final legacyCacheKey = value[_legacyCacheKeyField] as String?;
      final cacheInfo = await _getAudioCacheInfo(entry.key) ??
          (legacyCacheKey == null
              ? null
              : await _getAudioCacheInfo(legacyCacheKey));
      if (cacheInfo == null) {
        toRemove.add(entry.key);
        continue;
      }
      int bytes;
      try {
        bytes = await cacheInfo.file.length();
      } on FileSystemException {
        if (await cacheInfo.file.exists()) rethrow;
        toRemove.add(entry.key);
        continue;
      }
      final mediaItem = _mediaItemFromCachedPayload(value);
      final artists = (value['artists'] as List<dynamic>? ?? const [])
          .map((artist) => artist.toString())
          .toList();
      final cachedAt = DateTime.tryParse(
            value['cachedAt']?.toString() ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      entries.add(
        CachedAudioEntry(
          cacheKey: entry.key,
          title: value['title'] as String? ?? 'Unknown Track',
          album: value['album'] as String? ?? 'Unknown Album',
          artists: artists,
          cachedAt: cachedAt,
          bytes: bytes,
          mediaItem: mediaItem,
          legacyCacheKey: legacyCacheKey,
        ),
      );
    }

    if (toRemove.isNotEmpty || recovered) {
      for (final key in toRemove) {
        decoded.remove(key);
      }
      await _saveCachedAudioEntries(decoded, scope: scope);
    }

    entries.sort((a, b) => b.cachedAt.compareTo(a.cachedAt));
    return entries;
  }

  /// Removes a cached audio entry and evicts the file.
  Future<void> evictCachedAudio(String cacheKey) {
    final scope = _scope;
    _invalidateDownloads(scope, cacheKey: cacheKey);
    return _serialized(() async {
      await backgroundDownloads?.cancel(scope: scope, key: cacheKey);
      CachedAudioEntry? entry;
      for (final candidate in await _loadCachedAudioEntriesForScope(scope)) {
        if (candidate.cacheKey == cacheKey) {
          entry = candidate;
          break;
        }
      }
      await _deleteAudioFile(cacheKey, legacyCacheKey: entry?.legacyCacheKey);
      await _forgetCachedAudio(cacheKey, scope: scope);
    });
  }

  /// Enforces the cache size limit using LRU eviction.
  Future<void> enforceCacheLimit({int? maxBytes, String? scope}) {
    final cacheScope = scope ?? _scope;
    return _serialized(
        () => _enforceCacheLimit(cacheScope, maxBytes: maxBytes));
  }

  Future<void> _enforceCacheLimit(String? cacheScope, {int? maxBytes}) async {
    final limit = maxBytes ?? await loadCacheMaxBytes();
    if (limit <= 0) {
      return;
    }
    final entries = await _loadCachedAudioEntriesForScope(cacheScope);
    final pinned = await _loadPinnedAudio(scope: cacheScope);
    if (entries.isEmpty) {
      return;
    }
    var total = entries
        .where((entry) => !pinned.contains(entry.cacheKey))
        .fold<int>(0, (sum, entry) => sum + entry.bytes);
    if (total <= limit) {
      return;
    }
    entries.sort((a, b) => a.cachedAt.compareTo(b.cachedAt));
    final toRemove = <CachedAudioEntry>[];
    for (final entry in entries) {
      if (pinned.contains(entry.cacheKey)) {
        continue;
      }
      toRemove.add(entry);
      total -= entry.bytes;
      if (total <= limit) {
        break;
      }
    }
    if (toRemove.isEmpty) {
      return;
    }
    for (final entry in toRemove) {
      await _deleteAudioFile(
        entry.cacheKey,
        legacyCacheKey: entry.legacyCacheKey,
      );
    }
    await _forgetCachedAudioEntries(
      toRemove.map((entry) => entry.cacheKey).toSet(),
      scope: cacheScope,
    );
  }

  Future<void> _deleteAudioFile(
    String cacheKey, {
    String? legacyCacheKey,
  }) async {
    for (final key in {cacheKey, if (legacyCacheKey != null) legacyCacheKey}) {
      final file = (await _getAudioCacheInfo(key))?.file;
      if (file != null) {
        try {
          await file.delete();
        } on FileSystemException {
          if (await file.exists()) rethrow;
        }
      }
      await _audioCache.removeFile(key);
      await backgroundDownloads?.forget(key);
      final directory = (await retainedAudioFile(key)).parent;
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  /// Returns the directory used by the media cache.
  Future<Directory> getMediaCacheDirectory() async {
    final baseDir = await getApplicationSupportDirectory();
    return Directory('${baseDir.path}/offline_audio');
  }

  /// Opens the cached media directory in the OS file manager.
  Future<void> openMediaCacheLocation() async {
    try {
      final directory = await getMediaCacheDirectory();
      await directory.create(recursive: true);
      if (Platform.isMacOS) {
        await Process.run('open', [directory.path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [directory.path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [directory.path]);
      }
    } catch (_) {
      // Ignore failures to open system file manager.
    }
  }

  Future<void> _saveList(String key, List<Object> items) {
    final storageKey = _scopedKey(key, _scope);
    final encoded = jsonEncode(items);
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(storageKey, encoded);
    });
  }

  Future<List<T>> _loadList<T>(
    String key,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final storageKey = _scopedKey(key, _scope);
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(storageKey);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List<dynamic>)
          .map((entry) => fromJson(entry as Map<String, dynamic>))
          .toList();
    });
  }

  Future<void> _saveTrackMap(
    String key,
    String id,
    List<MediaItem> tracks,
  ) {
    final scope = _scope;
    final encodedTracks = tracks.map((track) => track.toJson()).toList();
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_scopedKey(key, scope));
      final Map<String, dynamic> decoded = raw == null || raw.isEmpty
          ? {}
          : jsonDecode(raw) as Map<String, dynamic>;
      decoded[id] = encodedTracks;
      await preferences.setString(_scopedKey(key, scope), jsonEncode(decoded));
    });
  }

  Future<List<MediaItem>> _loadTrackMap(String key, String id) {
    final storageKey = _scopedKey(key, _scope);
    return _serialized(() async {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(storageKey);
      if (raw == null || raw.isEmpty) {
        return [];
      }
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final items = decoded[id] as List<dynamic>?;
      if (items == null) {
        return [];
      }
      return items
          .map((entry) => MediaItem.fromJson(entry as Map<String, dynamic>))
          .toList();
    });
  }

  Future<void> _rememberCachedAudio(
    MediaItem item, {
    required String? scope,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_scopedKey(_cachedAudioKey, scope));
    final Map<String, dynamic> decoded = raw == null || raw.isEmpty
        ? {}
        : jsonDecode(raw) as Map<String, dynamic>;
    final cacheKey = _audioKeyForStreamUrl(item.streamUrl, scope);
    final existing = decoded[cacheKey];
    decoded[cacheKey] = {
      if (existing is Map && existing[_legacyCacheKeyField] is String)
        _legacyCacheKeyField: existing[_legacyCacheKeyField],
      'title': item.title,
      'album': item.album,
      'artists': item.artists,
      'mediaItem': item.toJson(),
      'cachedAt': DateTime.now().toIso8601String(),
    };
    await _saveCachedAudioEntries(decoded, scope: scope);
  }

  Future<FileInfo> _retainAudio(String key, FileInfo source) async {
    var destination = await retainedAudioFile(key);
    if (source.file.path != destination.path && !await destination.exists()) {
      final reader = await source.file.open();
      String? mime;
      try {
        mime = lookupMimeType(source.file.path,
            headerBytes: await reader.read(512));
      } finally {
        await reader.close();
      }
      final extension = switch (mime) {
        'audio/mpeg' => 'mp3',
        'audio/flac' || 'audio/x-flac' => 'flac',
        'audio/ogg' || 'application/ogg' => 'ogg',
        'audio/mp4' || 'video/mp4' => 'm4a',
        'audio/aac' => 'aac',
        'audio/wav' || 'audio/x-wav' => 'wav',
        _ => 'bin',
      };
      destination = File('${destination.parent.path}/audio.$extension');
      await destination.parent.create(recursive: true);
      final partial = await source.file.copy('${destination.path}.part');
      await partial.rename(destination.path);
      await source.file.delete();
    }
    return FileInfo(const LocalFileSystem().file(destination.path),
        source.source, source.validTill, source.originalUrl);
  }

  Future<FileInfo?> _getAudioCacheInfo(String cacheKey) async {
    final file = await retainedAudioFile(cacheKey);
    if (await file.exists()) {
      return FileInfo(const LocalFileSystem().file(file.path), FileSource.Cache,
          DateTime(2100), cacheKey);
    }
    final completed = await backgroundDownloads?.completedFile(cacheKey);
    if (completed != null) return _retainAudio(cacheKey, completed);
    final legacy = await _audioCache.getFileFromCache(cacheKey);
    if (legacy == null) return null;
    try {
      return await _retainAudio(cacheKey, legacy);
    } on FileSystemException {
      if (await legacy.file.exists()) rethrow;
      return null;
    }
  }

  Future<FileInfo?> _getAudioCacheInfoForItem(
    MediaItem item, {
    required String? scope,
  }) async {
    final cacheKey = _audioKeyForStreamUrl(item.streamUrl, scope);
    if (_audioDownloads.any(
        (download) => download.cacheKey == cacheKey && download.invalidated)) {
      return null;
    }
    final cached = await _getAudioCacheInfo(cacheKey);
    if (cached != null) {
      return _retainAudio(cacheKey, cached);
    }
    final entries = _readJsonMap(
      (await SharedPreferences.getInstance())
          .getString(_scopedKey(_cachedAudioKey, scope)),
    );
    final entry = entries[cacheKey];
    if (entry is! Map) {
      return null;
    }
    final legacyCacheKey = entry[_legacyCacheKeyField] as String?;
    final legacy = legacyCacheKey == null
        ? null
        : await _getAudioCacheInfo(legacyCacheKey);
    return legacy == null ? null : _retainAudio(cacheKey, legacy);
  }

  MediaItem? _mediaItemFromCachedPayload(Map<String, dynamic> payload) {
    final raw = payload['mediaItem'];
    if (raw is! Map) {
      return null;
    }
    try {
      return MediaItem.fromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<void> _forgetCachedAudio(String cacheKey, {required String? scope}) =>
      _forgetCachedAudioEntries({cacheKey}, scope: scope);

  Future<Set<String>> _loadPinnedAudio({required String? scope}) async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_scopedKey(_pinnedAudioKey, scope));
    if (raw == null || raw.isEmpty) {
      return {};
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.map((entry) => entry.toString()).toSet();
  }

  Future<void> _savePinnedAudio(Set<String> urls,
      {required String? scope}) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _scopedKey(_pinnedAudioKey, scope),
      jsonEncode(
        urls.map((url) => _audioKeyForStreamUrl(url, scope)).toSet().toList(),
      ),
    );
  }

  /// Pins or unpins a cached track for offline use.
  Future<void> setPinnedAudio(String streamUrl, bool pinned) {
    final scope = _scope;
    return _serialized(() async {
      await _setPinnedAudio(streamUrl, pinned, scope: scope);
    });
  }

  Future<void> _setPinnedAudio(
    String streamUrl,
    bool pinned, {
    required String? scope,
  }) async {
    final cacheKey = _audioKeyForStreamUrl(streamUrl, scope);
    final current = await _loadPinnedAudio(scope: scope);
    if (pinned) {
      current.add(cacheKey);
    } else {
      current.remove(cacheKey);
    }
    await _savePinnedAudio(current, scope: scope);
    if (!pinned) await _forgetPinnedAudioItems({cacheKey}, scope: scope);
  }

  /// Pins or unpins a track and persists enough metadata to resume downloads.
  Future<void> setPinnedAudioItem(MediaItem item, bool pinned) {
    final scope = _scope;
    return _serialized(() async {
      if (pinned) await _savePinnedAudioItems([item], scope: scope);
      await _setPinnedAudio(item.streamUrl, pinned, scope: scope);
    });
  }

  /// Applies a collection's pin intent without read/modify/write snapshots in
  /// AppState or a full preferences rewrite for each song.
  Future<Set<String>> updateOfflineSelection(List<MediaItem> items,
      {required bool pinned, bool wholeLibrary = false}) {
    final scope = _scope;
    final snapshot = List<MediaItem>.of(items);
    return _serialized(() async {
      final pins = await _loadPinnedAudio(scope: scope);
      final whole = await _loadWholeLibraryPinnedAudio(scope: scope);
      final keys = snapshot
          .map((item) => _audioKeyForStreamUrl(item.streamUrl, scope))
          .toSet();
      if (pinned) {
        if (wholeLibrary) {
          whole.addAll(keys.difference(pins));
        } else {
          whole.removeAll(keys);
        }
        await _savePinnedAudioItems(snapshot, scope: scope);
        pins.addAll(keys);
      } else {
        for (final key in keys) {
          _invalidateDownloads(scope, cacheKey: key);
        }
        await backgroundDownloads?.cancel(scope: scope, keys: keys);
        pins.removeAll(keys);
        whole.removeAll(keys);
      }
      await _savePinnedAudio(pins, scope: scope);
      if (!pinned) await _forgetPinnedAudioItems(keys, scope: scope);
      await _saveWholeLibraryPinnedAudio(whole, scope: scope);
      if (!pinned) await _enforceCacheLimit(scope);
      return whole;
    });
  }

  Future<Set<String>> removeWholeLibrarySelection() {
    final scope = _scope;
    return _serialized(() async {
      final whole = await _loadWholeLibraryPinnedAudio(scope: scope);
      final pins = await _loadPinnedAudio(scope: scope);
      for (final key in whole) {
        _invalidateDownloads(scope, cacheKey: key);
      }
      await backgroundDownloads?.cancel(scope: scope, keys: whole);
      await _savePinnedAudio(pins..removeAll(whole), scope: scope);
      await _forgetPinnedAudioItems(whole, scope: scope);
      await _saveWholeLibraryPinnedAudio({}, scope: scope);
      await _enforceCacheLimit(scope);
      return whole;
    });
  }

  /// Returns whether a track is pinned for offline playback.
  Future<bool> isPinnedAudio(String streamUrl) {
    final scope = _scope;
    return _serialized(() async {
      final pinned = await _loadPinnedAudio(scope: scope);
      return pinned.contains(_audioKeyForStreamUrl(streamUrl, scope));
    });
  }

  /// Loads pinned cache keys for offline playback.
  Future<Set<String>> loadPinnedAudio() {
    final scope = _scope;
    return _serialized(() async {
      return _loadPinnedAudio(scope: scope);
    });
  }

  /// Loads metadata for tracks that are pinned for offline playback.
  Future<List<MediaItem>> loadPinnedAudioItems() {
    final scope = _scope;
    return _serialized(() async {
      final pinned = await _loadPinnedAudio(scope: scope);
      if (pinned.isEmpty) {
        return [];
      }
      final preferences = await SharedPreferences.getInstance();
      final raw =
          preferences.getString(_scopedKey(_pinnedAudioItemsKey, scope));
      if (raw == null || raw.isEmpty) {
        return [];
      }
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final items = <MediaItem>[];
      final toRemove = <String>[];
      for (final entry in decoded.entries) {
        if (!pinned.contains(entry.key)) continue;
        final value = entry.value;
        if (value is! Map) {
          toRemove.add(entry.key);
          continue;
        }
        try {
          items.add(MediaItem.fromJson(value.cast<String, dynamic>()));
        } catch (_) {
          toRemove.add(entry.key);
        }
      }
      if (toRemove.isNotEmpty) {
        for (final key in toRemove) {
          decoded.remove(key);
        }
        await preferences.setString(
          _scopedKey(_pinnedAudioItemsKey, scope),
          jsonEncode(decoded),
        );
      }
      return items;
    });
  }

  /// Saves metadata for pinned tracks in one pass.
  Future<void> savePinnedAudioItems(Iterable<MediaItem> items) {
    final scope = _scope;
    final snapshot = items.toList(growable: false);
    return _serialized(() => _savePinnedAudioItems(snapshot, scope: scope));
  }

  Future<void> _savePinnedAudioItems(Iterable<MediaItem> items,
      {required String? scope}) async {
    if (items.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_scopedKey(_pinnedAudioItemsKey, scope));
    final decoded = raw == null || raw.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    for (final item in items) {
      decoded[_audioKeyForStreamUrl(item.streamUrl, scope)] = item.toJson();
    }
    await preferences.setString(
        _scopedKey(_pinnedAudioItemsKey, scope), jsonEncode(decoded));
  }

  /// Replaces pinned cache keys, accepting legacy stream URLs.
  Future<void> savePinnedAudio(Set<String> urls) {
    final scope = _scope;
    final snapshot = Set<String>.of(urls);
    return _serialized(() => _savePinnedAudio(snapshot, scope: scope));
  }

  /// Removes pinned track metadata in one pass.
  Future<void> forgetPinnedAudioItems(Iterable<String> streamUrls) {
    final scope = _scope;
    final keys =
        streamUrls.map((url) => _audioKeyForStreamUrl(url, scope)).toSet();
    return _serialized(() => _forgetPinnedAudioItems(keys, scope: scope));
  }

  Future<Set<String>> _loadWholeLibraryPinnedAudio(
      {required String? scope}) async {
    final preferences = await SharedPreferences.getInstance();
    final raw =
        preferences.getString(_scopedKey(_wholeLibraryPinnedAudioKey, scope));
    if (raw == null || raw.isEmpty) {
      return {};
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.map((entry) => entry.toString()).toSet();
  }

  Future<void> _saveWholeLibraryPinnedAudio(
    Set<String> urls, {
    required String? scope,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _scopedKey(_wholeLibraryPinnedAudioKey, scope),
      jsonEncode(
        urls
            .map((streamUrl) => _audioKeyForStreamUrl(streamUrl, scope))
            .toSet()
            .toList(),
      ),
    );
  }

  /// Tracks pins created by the whole-library offline action.
  Future<void> setWholeLibraryPinnedAudio(String streamUrl, bool pinned) {
    final scope = _scope;
    return _serialized(() async {
      final cacheKey = _audioKeyForStreamUrl(streamUrl, scope);
      final current = await _loadWholeLibraryPinnedAudio(scope: scope);
      if (pinned) {
        current.add(cacheKey);
      } else {
        current.remove(cacheKey);
      }
      await _saveWholeLibraryPinnedAudio(current, scope: scope);
    });
  }

  /// Loads pins created by the whole-library offline action.
  Future<Set<String>> loadWholeLibraryPinnedAudio() {
    final scope = _scope;
    return _serialized(() async {
      return _loadWholeLibraryPinnedAudio(scope: scope);
    });
  }

  /// Replaces the set of pins created by the whole-library offline action.
  Future<void> saveWholeLibraryPinnedAudio(Set<String> urls) {
    final scope = _scope;
    final snapshot = Set<String>.of(urls);
    return _serialized(
        () => _saveWholeLibraryPinnedAudio(snapshot, scope: scope));
  }

  Future<void> _forgetPinnedAudioItems(Set<String> keys,
      {required String? scope}) async {
    if (keys.isEmpty) return;
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_scopedKey(_pinnedAudioItemsKey, scope));
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    for (final key in keys) {
      decoded.remove(key);
    }
    await preferences.setString(
        _scopedKey(_pinnedAudioItemsKey, scope), jsonEncode(decoded));
  }

  Future<void> _forgetCachedAudioEntries(
    Set<String> streamUrls, {
    required String? scope,
  }) async {
    if (streamUrls.isEmpty) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_scopedKey(_cachedAudioKey, scope));
    if (raw == null || raw.isEmpty) {
      return;
    }
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    for (final url in streamUrls) {
      decoded.remove(url);
    }
    await _saveCachedAudioEntries(decoded, scope: scope);
  }

  Future<void> _saveCachedAudioEntries(
    Map<String, dynamic> entries, {
    required String? scope,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _scopedKey(_cachedAudioKey, scope),
      jsonEncode(entries),
    );
  }
}

// Cache-manager transfers outlive stream listeners; retain ownership until done.
class _AudioDownload {
  _AudioDownload(this.scope, this.cacheKey, this.createdAt);

  final String? scope;
  final String cacheKey;
  final DateTime createdAt;
  final finished = Completer<void>();
  bool invalidated = false;
}
