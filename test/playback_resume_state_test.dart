import 'package:coppelia/models/media_item.dart';
import 'package:coppelia/models/playback_resume_state.dart';
import 'package:flutter_test/flutter_test.dart';

MediaItem track(String id) => MediaItem(
      id: id,
      title: id,
      album: 'Album',
      artists: const [],
      duration: const Duration(minutes: 3),
      imageUrl: null,
      streamUrl: 'https://example.com/Audio/$id',
    );

void main() {
  test('resume retains queue order and the correct occurrence of a song', () {
    final repeated = track('repeated');
    final snapshot = PlaybackResumeState(
      track: repeated,
      position: const Duration(seconds: 42),
      queue: [repeated, track('other'), repeated, track('next')],
      currentIndex: 2,
    );
    final restored = PlaybackResumeState.fromJson(snapshot.toJson())!;
    expect(restored.queue.map((item) => item.id), [
      'repeated',
      'other',
      'repeated',
      'next',
    ]);
    expect(restored.currentIndex, 2);
    expect(restored.track, same(restored.queue[2]));
    expect(restored.position, const Duration(seconds: 42));
  });

  test('old snapshots still restore a single song and its position', () {
    final restored = PlaybackResumeState.fromJson({
      'track': track('old').toJson(),
      'positionMs': 17000,
    })!;
    expect(restored.queue.single.id, 'old');
    expect(restored.currentIndex, 0);
    expect(restored.position, const Duration(seconds: 17));
  });

  test('invalid queue index falls back to the saved current song', () {
    final restored = PlaybackResumeState.fromJson({
      'track': track('current').toJson(),
      'queue': [track('other').toJson()],
      'currentIndex': 9,
      'positionMs': 17000,
    })!;
    expect(restored.queue.single.id, 'current');
    expect(restored.currentIndex, 0);
  });
}
