import 'package:audio_fixer/app/app_theme.dart';
import 'package:audio_fixer/core/models/audio_track.dart';
import 'package:audio_fixer/core/models/source_query_report.dart';
import 'package:audio_fixer/shared/widgets/notice_panel.dart';
import 'package:audio_fixer/shared/widgets/source_query_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SourceQueryReport _blocked(DateTime now, {bool serverWait = false}) =>
    SourceQueryReport(
      sourceName: 'LRCLIB',
      outcome: SourceQueryOutcome.failed,
      message: '请求未完成，原资料已保留。',
      requestedFields: {AudioField.lyrics},
      failureKind: serverWait
          ? SourceFailureKind.rateLimited
          : SourceFailureKind.timeout,
      statusCode: serverWait ? 429 : null,
      retryAt: now.add(const Duration(seconds: 52)),
      serverRetryAt: serverWait ? now.add(const Duration(seconds: 52)) : null,
      isLocalCooldown: !serverWait,
    );

const _empty = SourceQueryReport(
  sourceName: '网易云音乐',
  outcome: SourceQueryOutcome.noMatch,
  message: '查询已完成，未找到可确认的录音。',
  requestedFields: {AudioField.title, AudioField.artist, AudioField.lyrics},
);
const _unsupported = SourceQueryReport(
  sourceName: '封面来源',
  outcome: SourceQueryOutcome.unsupported,
  message: '本次查询不需要封面。',
);

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  theme: buildAppTheme(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

void main() {
  testWidgets(
    'selected recording conflict is never presented as catalog absence',
    (tester) async {
      await tester.pumpWidget(
        _app(
          const SourceQueryStatusPanel(
            reports: [
              SourceQueryReport(
                sourceName: '网易云音乐',
                outcome: SourceQueryOutcome.failed,
                failureKind: SourceFailureKind.identityConflict,
                message: '已选录音详情与候选中的完整歌手不一致。',
              ),
            ],
          ),
        ),
      );
      expect(find.text('网易云音乐 · 录音信息不一致'), findsOneWidget);
      expect(find.textContaining('未找到匹配'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'absolute countdown expires without retry and allows one manual action',
    (tester) async {
      var now = DateTime(2026, 10, 3);
      final report = _blocked(now);
      var requests = 0;
      await tester.pumpWidget(
        _app(
          SourceQueryStatusPanel(
            reports: [report, _unsupported],
            now: () => now,
            retryKey: const ValueKey('retry'),
            onRetry: () => requests++,
          ),
        ),
      );
      expect(find.textContaining('本机暂停重试 · 52 秒'), findsOneWidget);
      expect(find.textContaining('连接超时'), findsOneWidget);
      expect(find.textContaining('429'), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('retry')))
            .onPressed,
        isNull,
      );
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('本机暂停重试 · 51 秒'), findsOneWidget);
      expect(find.textContaining('52 秒'), findsNothing);
      now = now.add(const Duration(seconds: 51));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('等待已结束，可手动重试'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const ValueKey('retry')))
            .onPressed,
        isNotNull,
      );
      expect(requests, 0);
      await tester.tap(find.byKey(const ValueKey('retry')));
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
      expect(requests, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one cooling provider keeps other provider query available', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 3);
    var requests = 0;
    await tester.pumpWidget(
      _app(
        SourceQueryStatusPanel(
          reports: [_blocked(now, serverWait: true), _empty],
          now: () => now,
          retryKey: const ValueKey('retry'),
          onRetry: () => requests++,
        ),
      ),
    );
    expect(find.textContaining('LRCLIB · 请求受限（429）'), findsOneWidget);
    expect(find.textContaining('来源要求等待 · 52 秒'), findsOneWidget);
    expect(find.text('网易云音乐 · 未找到匹配'), findsOneWidget);
    expect(find.text('查询其他可用来源'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry')));
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 60));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changing report restarts only presentation clock and disposal cancels it',
    (tester) async {
      final now = DateTime(2026, 10, 3);
      var requests = 0;
      final key = GlobalKey();
      Widget panel(List<SourceQueryReport> reports) => _app(
        SourceQueryStatusPanel(
          key: key,
          reports: reports,
          now: () => now,
          onRetry: () => requests++,
        ),
      );
      await tester.pumpWidget(panel([_empty]));
      await tester.pumpWidget(panel([_blocked(now)]));
      expect(find.textContaining('52 秒后可重试'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
      expect(requests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short server delay is not confused with longer local pause', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 3);
    await tester.pumpWidget(
      _app(
        SourceQueryStatusPanel(
          reports: [
            SourceQueryReport(
              sourceName: 'LRCLIB',
              outcome: SourceQueryOutcome.failed,
              message: '请求受限',
              failureKind: SourceFailureKind.rateLimited,
              retryAt: now.add(const Duration(seconds: 30)),
              serverRetryAt: now.add(const Duration(seconds: 10)),
            ),
          ],
          now: () => now,
        ),
      ),
    );
    expect(find.text('本机暂停重试 · 30 秒后可重试'), findsOneWidget);
    expect(find.textContaining('来源要求等待'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '$brightness source result fits narrow large text and uses contrast pair',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 740);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final now = DateTime(2026, 10, 3);
        await tester.pumpWidget(
          _app(
            SourceQueryStatusPanel(
              reports: [_empty, _blocked(now)],
              hasCandidates: true,
              now: () => now,
            ),
            brightness: brightness,
            scale: 2,
          ),
        );
        expect(find.text('可用候选已保留'), findsOneWidget);
        expect(find.text('可以继续确认候选资料'), findsOneWidget);
        final context = tester.element(find.byType(SourceQueryStatusPanel));
        final scheme = Theme.of(context).colorScheme;
        final foreground = tester
            .widget<Text>(find.text('LRCLIB · 连接超时'))
            .style!
            .color!;
        expect(foreground, scheme.onSurface);
        final a = foreground.computeLuminance();
        final b = scheme.surfaceContainer.computeLuminance();
        expect(
          ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05),
          greaterThan(4.5),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '$brightness error notice action uses same contrast foreground',
      (tester) async {
        await tester.pumpWidget(
          _app(
            NoticePanel(
              icon: Icons.error_outline,
              title: '保存失败',
              message: '请稍后重试',
              isError: true,
              action: TextButton(onPressed: () {}, child: const Text('重试')),
            ),
            brightness: brightness,
          ),
        );
        final context = tester.element(find.byType(TextButton));
        expect(
          TextButtonTheme.of(context).style!.foregroundColor!.resolve({}),
          Theme.of(context).colorScheme.onErrorContainer,
        );
      },
    );
  }
}
