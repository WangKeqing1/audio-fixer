import 'dart:async';
import 'dart:typed_data';

import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/device_artwork_cache.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class PendingArtworkSource implements DeviceArtworkSource {
  @override
  int artworkRevision = 0;
  final calls = <String>[];
  final results = <Completer<Uint8List?>>[];

  @override
  Future<Uint8List?> readArtworkThumbnail(AudioTrack track) {
    calls.add(track.contentUri!);
    final result = Completer<Uint8List?>();
    results.add(result);
    return result.future;
  }
}

void main() {
  test(
    'deduplicates reads and caches absent artwork without inspecting tags',
    () async {
      final source = PendingArtworkSource();
      final cache = DeviceArtworkCache(source);
      final track = fixtureDeviceTrack();
      final first = cache.request(track);
      final second = cache.request(track);
      expect(source.calls, hasLength(1));
      source.results.single.complete();
      expect(await first.result, isNull);
      expect(await second.result, isNull);
      expect(await cache.request(track).result, isNull);
      expect(source.calls, hasLength(1));
      expect(track.detailsLoaded, isFalse);
      expect(track.artworkPath, isNull);
      cache.dispose();
    },
  );

  test(
    'bounds reads and cancels queued rows released during scrolling',
    () async {
      final source = PendingArtworkSource();
      final cache = DeviceArtworkCache(source);
      final first = cache.request(fixtureDeviceTrack(id: '1'));
      final second = cache.request(fixtureDeviceTrack(id: '2'));
      final offscreen = cache.request(fixtureDeviceTrack(id: '3'));
      final visible = cache.request(fixtureDeviceTrack(id: '4'));
      expect(source.calls, hasLength(2));
      offscreen.release();
      expect(await offscreen.result, isNull);
      source.results.first.complete();
      await first.result;
      expect(source.calls, hasLength(3));
      expect(source.calls.last, endsWith('/4'));
      source.results[1].complete();
      source.results[2].complete();
      await Future.wait([second.result, visible.result]);
      cache.dispose();
    },
  );

  test(
    'URI, modification, size and scan revision invalidate thumbnails',
    () async {
      final source = PendingArtworkSource();
      final cache = DeviceArtworkCache(source);
      final original = fixtureDeviceTrack();
      final changed = fixtureDeviceTrack(modified: 2000);
      final anotherVolume = AudioTrack.fromJson({
        ...original.toJson(),
        'contentUri': 'content://media/ABCD-1234/audio/media/1',
      });
      final resized = AudioTrack.fromJson({
        ...original.toJson(),
        'sizeBytes': 9000,
      });
      expect(cache.keyFor(original), isNot(cache.keyFor(changed)));
      expect(cache.keyFor(original), isNot(cache.keyFor(anotherVolume)));
      expect(cache.keyFor(original), isNot(cache.keyFor(resized)));
      final old = cache.request(original);
      source.artworkRevision++;
      final refreshed = cache.request(original);
      source.results[0].complete(Uint8List.fromList([1]));
      source.results[1].complete(Uint8List.fromList([2]));
      expect(await old.result, isNull);
      expect(await refreshed.result, [2]);
      expect(await cache.request(original).result, [2]);
      expect(source.calls, hasLength(2));
      cache.dispose();
    },
  );

  test('LRU limits retained bytes and does not cache read failures', () async {
    final source = PendingArtworkSource();
    final cache = DeviceArtworkCache(source, maxEntries: 2, maxBytes: 3);
    final first = cache.request(fixtureDeviceTrack(id: '1'));
    source.results[0].complete(Uint8List.fromList([1, 1]));
    await first.result;
    final second = cache.request(fixtureDeviceTrack(id: '2'));
    source.results[1].complete(Uint8List.fromList([2, 2]));
    await second.result;
    final evicted = cache.request(fixtureDeviceTrack(id: '1'));
    expect(source.calls, hasLength(3));
    source.results[2].completeError(StateError('permission revoked'));
    expect(await evicted.result, isNull);
    final retry = cache.request(fixtureDeviceTrack(id: '1'));
    expect(source.calls, hasLength(4));
    source.results[3].complete();
    expect(await retry.result, isNull);
    cache.dispose();
  });

  test(
    'entry limit also bounds negative artwork cache with LRU eviction',
    () async {
      final source = PendingArtworkSource();
      final cache = DeviceArtworkCache(source, maxEntries: 2);
      for (var id = 1; id <= 2; id++) {
        final request = cache.request(fixtureDeviceTrack(id: '$id'));
        source.results.last.complete();
        await request.result;
      }
      await cache.request(fixtureDeviceTrack(id: '1')).result;
      final third = cache.request(fixtureDeviceTrack(id: '3'));
      source.results.last.complete();
      await third.result;
      await cache.request(fixtureDeviceTrack(id: '1')).result;
      expect(source.calls, hasLength(3));
      final evicted = cache.request(fixtureDeviceTrack(id: '2'));
      expect(source.calls, hasLength(4));
      source.results.last.complete();
      await evicted.result;
      cache.dispose();
    },
  );

  test(
    'refresh drops stale queued reads before starting current rows',
    () async {
      final source = PendingArtworkSource();
      final cache = DeviceArtworkCache(source, maxConcurrent: 1);
      final active = cache.request(fixtureDeviceTrack(id: '1'));
      final stale = cache.request(fixtureDeviceTrack(id: '2'));
      source.artworkRevision++;
      final current = cache.request(fixtureDeviceTrack(id: '3'));
      source.results.first.complete();
      await active.result;
      expect(await stale.result, isNull);
      expect(source.calls, hasLength(2));
      expect(source.calls.last, endsWith('/3'));
      source.results.last.complete();
      await current.result;
      cache.dispose();
    },
  );

  test(
    'disposal completes pending rows and ignores late native results',
    () async {
      final source = PendingArtworkSource();
      final cache = DeviceArtworkCache(source, maxConcurrent: 1);
      final active = cache.request(fixtureDeviceTrack(id: '1'));
      final queued = cache.request(fixtureDeviceTrack(id: '2'));
      cache.dispose();
      queued.release();
      expect(await active.result, isNull);
      expect(await queued.result, isNull);
      source.results.single.complete(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);
      expect(source.calls, hasLength(1));
      expect(await cache.request(fixtureDeviceTrack()).result, isNull);
    },
  );
}
