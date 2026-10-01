import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/services/sources/cover_art_archive_source.dart';
import 'package:audio_fixer/core/services/sources/json_api_client.dart';
import 'package:audio_fixer/core/services/sources/musicbrainz_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeJsonApiClient implements JsonApiClient {
  _FakeJsonApiClient(this.handler);

  final Future<Object?> Function(Uri uri) handler;
  final calls = <Uri>[];

  @override
  Future<Object?> getJson(Uri uri) {
    calls.add(uri);
    return handler(uri);
  }
}

AudioTrack _track() => AudioTrack(
  id: 'track',
  fileName: 'track.mp3',
  sizeBytes: 1,
  importedAt: DateTime(2026),
  title: 'Song',
  artist: 'Artist',
  durationMs: 200000,
);

Map<String, Object?> _recording() => {
  'id': 'recording-1',
  'title': 'Song',
  'length': 200000,
  'artist-credit': [
    {'name': 'Artist'},
  ],
  'releases': [
    {
      'id': 'release-1',
      'title': 'Album',
      'release-group': {'id': 'group-1'},
    },
  ],
};

void main() {
  test('returns only an approved front image from CAA', () async {
    final client = _FakeJsonApiClient((uri) async {
      if (uri.host == 'musicbrainz.org') {
        return {
          'recordings': [_recording()],
        };
      }
      return {
        'images': [
          {
            'front': false,
            'approved': true,
            'image': 'https://coverartarchive.org/release/rear.jpg',
          },
          {
            'front': true,
            'approved': false,
            'image': 'https://coverartarchive.org/release/unapproved.jpg',
          },
          {
            'front': true,
            'approved': true,
            'image': 'https://coverartarchive.org/release/front.jpg',
            'thumbnails': {
              '500': 'https://coverartarchive.org/release/front-500.jpg',
              'small': 'https://coverartarchive.org/release/front-250.jpg',
            },
          },
        ],
      };
    });
    final source = CoverArtArchiveSource(client, MusicBrainzCatalog(client));
    final suggestions = await source.lookup(_track(), {AudioField.artwork});

    expect(suggestions, hasLength(1));
    expect(
      suggestions.single.value,
      'https://coverartarchive.org/release/front-500.jpg',
    );
    expect(suggestions.single.source, 'Cover Art Archive');
  });

  test(
    'rejects untrusted artwork URLs and can use a group after release 404',
    () async {
      final client = _FakeJsonApiClient((uri) async {
        if (uri.host == 'musicbrainz.org') {
          return {
            'recordings': [_recording()],
          };
        }
        if (uri.path.startsWith('/release/')) return null;
        return {
          'images': [
            {
              'front': true,
              'approved': true,
              'image': 'http://coverartarchive.org/release/front.jpg',
              'thumbnails': {
                'small': 'https://evil.example/front.jpg',
                'large': 'https://archive.org/download/caa/front.jpg',
              },
            },
          ],
        };
      });
      final source = CoverArtArchiveSource(client, MusicBrainzCatalog(client));
      final suggestions = await source.lookup(_track(), {AudioField.artwork});

      expect(
        suggestions.single.value,
        'https://archive.org/download/caa/front.jpg',
      );
      expect(
        client.calls.map((uri) => uri.path),
        contains('/release-group/group-1'),
      );
    },
  );

  test('upgrades an allowed legacy HTTP thumbnail to HTTPS', () async {
    final client = _FakeJsonApiClient((uri) async {
      if (uri.host == 'musicbrainz.org') {
        return {
          'recordings': [_recording()],
        };
      }
      return {
        'images': [
          {
            'front': true,
            'approved': true,
            'image': 'http://coverartarchive.org/release/front.jpg',
            'thumbnails': {
              '500':
                  'http://coverartarchive.org/release/front-500.jpg?size=500',
            },
          },
        ],
      };
    });
    final source = CoverArtArchiveSource(client, MusicBrainzCatalog(client));
    final suggestions = await source.lookup(_track(), {AudioField.artwork});

    expect(
      suggestions.single.value,
      'https://coverartarchive.org/release/front-500.jpg?size=500',
    );
  });

  test('does not upgrade disallowed domains or explicit ports', () async {
    final client = _FakeJsonApiClient((uri) async {
      if (uri.host == 'musicbrainz.org') {
        return {
          'recordings': [_recording()],
        };
      }
      return {
        'images': [
          {
            'front': true,
            'approved': true,
            'image': 'http://coverartarchive.org:8080/release/front.jpg',
            'thumbnails': {
              '500': 'http://evil.example/release/front-500.jpg',
              '1200': 'https://archive.org:8443/release/front-1200.jpg',
            },
          },
        ],
      };
    });
    final source = CoverArtArchiveSource(client, MusicBrainzCatalog(client));

    expect(await source.lookup(_track(), {AudioField.artwork}), isEmpty);
  });

  test('CAA errors are not converted to no match', () async {
    final client = _FakeJsonApiClient((uri) async {
      if (uri.host == 'musicbrainz.org') {
        return {
          'recordings': [_recording()],
        };
      }
      throw const ApiException('CAA unavailable');
    });
    final source = CoverArtArchiveSource(client, MusicBrainzCatalog(client));
    expect(
      () => source.lookup(_track(), {AudioField.artwork}),
      throwsA(isA<ApiException>()),
    );
  });

  test('CAA connection probe accepts a normal 404', () async {
    final client = _FakeJsonApiClient((_) async => null);
    await CoverArtArchiveSource(
      client,
      MusicBrainzCatalog(client),
    ).checkConnection();
    expect(
      client.calls.single.path,
      '/release/76df3287-6cda-33eb-8e9a-044b5e15ffdd',
    );
  });

  test('CAA connection probe validates images on a 200 response', () async {
    final client = _FakeJsonApiClient((_) async => {'release': 'known'});
    await expectLater(
      CoverArtArchiveSource(
        client,
        MusicBrainzCatalog(client),
      ).checkConnection(),
      throwsA(isA<FormatException>()),
    );
  });
}
