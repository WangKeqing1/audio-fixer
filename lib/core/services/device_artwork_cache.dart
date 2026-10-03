import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../models/audio_track.dart';

/// Optional device capability: reads only a small, per-file embedded thumbnail.
/// These bytes are presentation data, not a completed tag inspection.
abstract interface class DeviceArtworkSource {
  int get artworkRevision;
  Future<Uint8List?> readArtworkThumbnail(AudioTrack track);
}

class ArtworkThumbnailRequest {
  ArtworkThumbnailRequest(this.key, this.result, this._release);

  final Object key;
  final Future<Uint8List?> result;
  final void Function() _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// A page-scoped LRU. Only mounted rows enqueue work, disposed rows release it,
/// and both concurrent native reads and retained thumbnail bytes are bounded.
class DeviceArtworkCache {
  DeviceArtworkCache(
    this.source, {
    this.maxEntries = 80,
    this.maxBytes = 4 * 1024 * 1024,
    this.maxConcurrent = 2,
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0),
       assert(maxConcurrent > 0);

  final DeviceArtworkSource source;
  final int maxEntries;
  final int maxBytes;
  final int maxConcurrent;
  final _cache = <Object, Uint8List?>{};
  final _pending = <Object, _PendingThumbnail>{};
  final _queue = Queue<_PendingThumbnail>();
  int _cachedBytes = 0;
  int _active = 0;
  int? _revision;
  bool _disposed = false;

  Object keyFor(AudioTrack track) => (
    source.artworkRevision,
    track.contentUri,
    track.dateModifiedMs,
    track.sizeBytes,
    track.fileName,
    track.indexedDurationMs,
  );

  ArtworkThumbnailRequest request(AudioTrack track) {
    final key = keyFor(track);
    if (_disposed || !track.isDeviceTrack) {
      return ArtworkThumbnailRequest(key, Future.value(), () {});
    }
    if (_revision != source.artworkRevision) {
      _revision = source.artworkRevision;
      _cache.clear();
      _cachedBytes = 0;
    }
    if (_cache.containsKey(key)) {
      final bytes = _cache.remove(key);
      _cache[key] = bytes;
      return ArtworkThumbnailRequest(key, Future.value(bytes), () {});
    }
    var pending = _pending[key];
    if (pending == null) {
      pending = _PendingThumbnail(key, track, source.artworkRevision);
      _pending[key] = pending;
      _queue.add(pending);
    }
    final entry = pending;
    entry.readers++;
    _drain();
    return ArtworkThumbnailRequest(key, entry.result.future, () {
      entry.readers--;
      if (entry.readers == 0 && !entry.started) {
        _queue.remove(entry);
        _pending.remove(key);
        if (!entry.result.isCompleted) entry.result.complete();
      }
    });
  }

  void _drain() {
    while (!_disposed && _active < maxConcurrent && _queue.isNotEmpty) {
      final entry = _queue.removeFirst();
      if (entry.revision != source.artworkRevision) {
        _pending.remove(entry.key);
        entry.result.complete();
        continue;
      }
      entry.started = true;
      _active++;
      unawaited(_read(entry));
    }
  }

  Future<void> _read(_PendingThumbnail entry) async {
    Uint8List? bytes;
    var succeeded = false;
    try {
      bytes = await source.readArtworkThumbnail(entry.track);
      succeeded = true;
    } catch (_) {
      // Permission loss, removed files and unsupported media keep the normal
      // placeholder. Errors are not cached as proof that artwork is absent.
    } finally {
      _active--;
      _pending.remove(entry.key);
      final current = !_disposed && entry.revision == source.artworkRevision;
      if (current && succeeded) _remember(entry.key, bytes);
      if (!entry.result.isCompleted) {
        entry.result.complete(current ? bytes : null);
      }
      _drain();
    }
  }

  void _remember(Object key, Uint8List? bytes) {
    if (bytes != null && bytes.lengthInBytes > maxBytes) return;
    _cachedBytes += bytes?.lengthInBytes ?? 0;
    _cache[key] = bytes;
    while (_cache.length > maxEntries || _cachedBytes > maxBytes) {
      _cachedBytes -= _cache.remove(_cache.keys.first)?.lengthInBytes ?? 0;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _pending.values) {
      if (!entry.result.isCompleted) entry.result.complete();
    }
    _queue.clear();
    _pending.clear();
    _cache.clear();
    _cachedBytes = 0;
  }
}

class _PendingThumbnail {
  _PendingThumbnail(this.key, this.track, this.revision);
  final Object key;
  final AudioTrack track;
  final int revision;
  final result = Completer<Uint8List?>();
  int readers = 0;
  bool started = false;
}
