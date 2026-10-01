import 'package:audio_fixer/core/models/app_settings.dart';
import 'package:audio_fixer/core/models/completion_task.dart';
import 'package:audio_fixer/core/storage/library_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('batch import preserves successes, skips duplicates and tolerates a failed file', () async {
    final store = MemoryStore();
    final picker = FakePicker()
      ..names = ['same.mp3', 'same.mp3', 'unreadable.mp3'];
    final controller = testController(store: store, picker: picker);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.importAudio();
    expect(controller.tracks, hasLength(1));
    expect(store.snapshot.tracks, hasLength(1));
    expect(controller.notice, contains('重复'));
    expect(controller.notice, contains('导入失败'));
    expect(controller.isBusy, isFalse);
  });

  test('cancelling picker leaves library and notification unchanged', () async {
    final controller = testController();
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.importAudio();
    expect(controller.tracks, isEmpty);
    expect(controller.notice, isNull);
    expect(controller.canOperate, isTrue);
  });

  test('save failure does not publish unpersisted settings', () async {
    final store = MemoryStore()..failSave = true;
    final controller = testController(store: store);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.updateSettings(const AppSettings(theme: AppTheme.dark));
    expect(controller.settings.theme, AppTheme.system);
    expect(controller.notice, contains('操作未完成'));
  });

  test(
    'load failure blocks writes and retry recovers existing library',
    () async {
      final store = MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()]))
        ..failLoad = true;
      final controller = testController(store: store);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.canOperate, isFalse);
      expect(controller.loadError, isNotNull);
      await controller.updateSettings(const AppSettings(theme: AppTheme.dark));
      expect(store.snapshot.tracks, hasLength(1));
      store.failLoad = false;
      await controller.initialize();
      expect(controller.tracks, hasLength(1));
      expect(controller.loadError, isNull);
    },
  );

  test(
    'repeated requests replace the same task and survive controller restart',
    () async {
      final store = MemoryStore(LibrarySnapshot(tracks: [fixtureTrack()]));
      final controller = testController(store: store);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.complete();
      await controller.complete();
      expect(controller.tasks, hasLength(1));
      expect(controller.tasks.single.status, TaskStatus.waitingForSource);
      final restored = testController(store: store);
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.tasks.single.status, TaskStatus.waitingForSource);
      expect(restored.tracks.single.title, '测试歌曲');
    },
  );
}
