import 'dart:io';

import '../metadata_source.dart';
import 'cover_art_archive_source.dart';
import 'http_json_api_client.dart';
import 'json_api_client.dart';
import 'lrclib_source.dart';
import 'musicbrainz_source.dart';
import 'netease_lyrics_source.dart';

List<MetadataSource> createOnlineSources({
  JsonApiClient? client,
  Directory? cacheDirectory,
}) {
  final api = client ?? HttpJsonApiClient(cacheDirectory: cacheDirectory);
  final catalog = MusicBrainzCatalog(api);
  return [
    MusicBrainzMetadataSource(catalog),
    NeteaseLyricsSource(api),
    LrclibSource(api),
    CoverArtArchiveSource(api, catalog),
  ];
}
