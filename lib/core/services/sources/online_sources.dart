import '../metadata_source.dart';
import 'cover_art_archive_source.dart';
import 'http_json_api_client.dart';
import 'json_api_client.dart';
import 'lrclib_source.dart';
import 'musicbrainz_source.dart';

List<MetadataSource> createOnlineSources({JsonApiClient? client}) {
  final api = client ?? HttpJsonApiClient();
  final catalog = MusicBrainzCatalog(api);
  return [
    MusicBrainzMetadataSource(catalog),
    LrclibSource(api),
    CoverArtArchiveSource(api, catalog),
  ];
}
