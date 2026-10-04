// Authored offline fixtures that exercise the exact production LRCLIB URL shape.
// No network request, native write, or third-party lyrics are involved.
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/services/completion_service.dart';
import 'package:audio_fixer/core/services/export/audio_copy_exporter.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:audio_fixer/features/library/library_controller.dart';

import 'fakes.dart';

const expandedReviewSourceUrl = 'https://lrclib.net/api/get/123456';
String _lines(String text) => List.generate(100, (i) {
  final minute = (i ~/ 12).toString().padLeft(2, '0');
  final second = (i % 12 * 5).toString().padLeft(2, '0');
  return '[$minute:$second.00] $text ${i + 1}';
}).join('\n');
final expandedReviewLyrics = _lines('沿着树荫慢慢走，把午后的风留在身后');
final expandedReviewOldLyrics = _lines('原文件保留的离线测试歌词');
final expandedReviewTranslation = _lines('为测试创作的中文译文');

class ExpandedReviewWriter implements AudioCopyExporter, AudioOriginalSaver {
  int writeCount = 0;
  @override
  bool supports(AudioTrack track) => true;
  @override
  bool supportsOriginal(AudioTrack track) => true;
  @override
  Future<String?> export(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    writeCount++;
    return null;
  }

  @override
  Future<String?> saveOriginal(
    AudioTrack track,
    List<FieldSuggestion> selected,
  ) async {
    writeCount++;
    return null;
  }
}

class ExpandedReviewFixture {
  ExpandedReviewFixture({bool withExisting = false, bool translated = false}) {
    suggestion = FieldSuggestion(
      field: AudioField.lyrics,
      value: expandedReviewLyrics,
      originalLyrics: expandedReviewLyrics,
      chineseTranslation: translated ? expandedReviewTranslation : null,
      source: 'LRCLIB',
      sourceUrl: expandedReviewSourceUrl,
      matchDescription: '歌名与歌手匹配；专辑匹配；时长相差 0.3 秒。离线验证资料。',
      provenance: SuggestionProvenance.verifiedRecording,
      replaceExisting: withExisting,
    );
    final track = AudioTrack(
      id: 'expanded-review',
      fileName: '午后散步.flac',
      localPath: '/offline-synthetic/午后散步.flac',
      sizeBytes: 25800000,
      importedAt: DateTime(2026, 10, 4),
      title: '午后散步',
      artist: '林间来信',
      album: '树影与风',
      durationMs: 192000,
      lyrics: withExisting ? expandedReviewOldLyrics : null,
    );
    task = CompletionTask(
      trackId: track.id,
      trackTitle: track.displayTitle,
      createdAt: DateTime(2026, 10, 4),
      status: TaskStatus.needsReview,
      message: '为本次回归验证创作的离线资料，没有连接在线来源。',
      suggestions: [suggestion],
      isRepair: true,
    );
    controller = LibraryController(
      store: MemoryStore(LibrarySnapshot(tracks: [track], tasks: [task])),
      picker: FakePicker(),
      importer: FakeImporter(),
      completion: CompletionService(sources: [NoResultMetadataSource()]),
      exporter: writer,
    );
  }
  final writer = ExpandedReviewWriter();
  late final FieldSuggestion suggestion;
  late final CompletionTask task;
  late final LibraryController controller;
}
