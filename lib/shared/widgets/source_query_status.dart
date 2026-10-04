import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/source_query_report.dart';

/// Retry eligibility is provider scoped: a cooling source does not block a
/// healthy one. Unsupported providers cannot make a blocked query look ready.
class SourceRetryState {
  SourceRetryState(this.reports, this.now, {this.requestedSources});

  final List<SourceQueryReport> reports;
  final DateTime now;
  final Set<String>? requestedSources;

  List<SourceQueryReport> get _eligible => reports
      .where(
        (report) =>
            report.outcome != SourceQueryOutcome.unsupported &&
            (requestedSources == null ||
                requestedSources!.contains(report.sourceName)),
      )
      .toList();

  bool get hasCoolingSource =>
      _eligible.any((report) => report.isCoolingDown(now));

  bool get allSourcesCooling {
    final requested =
        requestedSources ??
        _eligible.map((report) => report.sourceName).toSet();
    return requested.isNotEmpty &&
        requested.every(
          (name) => _eligible.any(
            (report) => report.sourceName == name && report.isCoolingDown(now),
          ),
        );
  }

  int get retrySeconds {
    if (!allSourcesCooling) return 0;
    return _eligible
        .map((report) => report.retrySeconds(now))
        .reduce((a, b) => a < b ? a : b);
  }

  String label(String readyLabel) => allSourcesCooling
      ? '$retrySeconds 秒后可重试'
      : hasCoolingSource
      ? '查询其他可用来源'
      : readyLabel;
}

/// Only updates presentation. Expiry never starts a network request.
class SourceRetryBuilder extends StatefulWidget {
  const SourceRetryBuilder({
    super.key,
    required this.reports,
    required this.builder,
    this.requestedSources,
    this.now,
  });

  final List<SourceQueryReport> reports;
  final Widget Function(BuildContext context, SourceRetryState state) builder;
  final Set<String>? requestedSources;
  final DateTime Function()? now;

  @override
  State<SourceRetryBuilder> createState() => _SourceRetryBuilderState();
}

class _SourceRetryBuilderState extends State<SourceRetryBuilder>
    with WidgetsBindingObserver {
  Timer? _timer;

  DateTime get _now => widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncTimer();
  }

  @override
  void didUpdateWidget(SourceRetryBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTimer();
  }

  void _syncTimer() {
    final cooling = widget.reports.any((report) => report.isCoolingDown(_now));
    if (!cooling) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        _syncTimer();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      setState(() {});
      _syncTimer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    context,
    SourceRetryState(
      widget.reports,
      _now,
      requestedSources: widget.requestedSources,
    ),
  );
}

class SourceQueryStatusPanel extends StatelessWidget {
  const SourceQueryStatusPanel({
    super.key,
    required this.reports,
    this.hasCandidates = false,
    this.summary,
    this.onRetry,
    this.retryKey,
    this.retryLabel = '重试自动检索',
    this.retrySources,
    this.now,
  });

  final List<SourceQueryReport> reports;
  final bool hasCandidates;
  final String? summary;
  final VoidCallback? onRetry;
  final Key? retryKey;
  final String retryLabel;
  final Set<String>? retrySources;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) => SourceRetryBuilder(
    reports: reports,
    requestedSources: retrySources,
    now: now,
    builder: (context, retry) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final hasFailure = reports.any(
        (report) =>
            report.outcome == SourceQueryOutcome.failed ||
            report.outcome == SourceQueryOutcome.partial,
      );
      final title = summary != null
          ? '来源查询记录'
          : hasCandidates
          ? '可用候选已保留'
          : hasFailure
          ? '来源查询未完成'
          : '检索完成';
      return Material(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
        color: colors.surfaceContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: colors.onSurface,
                ),
              ),
              if (summary != null) ...[
                const SizedBox(height: 4),
                Text(
                  summary!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface,
                  ),
                ),
              ] else if (hasCandidates) ...[
                const SizedBox(height: 4),
                Text(
                  '可以继续确认候选资料',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              for (var index = 0; index < reports.length; index++) ...[
                if (index > 0) const SizedBox(height: 10),
                _SourceStatusRow(report: reports[index], now: retry.now),
              ],
              if (onRetry != null || retryKey != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: retryKey,
                    onPressed: retry.allSourcesCooling ? null : onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text(retry.label(retryLabel)),
                  ),
                ),
              ],
              if (retry.hasCoolingSource) ...[
                const SizedBox(height: 4),
                Text(
                  '倒计时结束后可手动重试',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                title: const Text('查看来源详情'),
                dense: true,
                children: [
                  for (final report in reports)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${report.sourceName}：${report.message}'
                        '${report.requestedFields.isEmpty ? '' : '\n查询内容：${report.requestedFields.map((field) => field.label).join('、')}'}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _SourceStatusRow extends StatelessWidget {
  const _SourceStatusRow({required this.report, required this.now});

  final SourceQueryReport report;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final failed =
        report.outcome == SourceQueryOutcome.failed ||
        report.outcome == SourceQueryOutcome.partial;
    final icon = switch (report.outcome) {
      SourceQueryOutcome.success => Icons.check_circle_outline,
      SourceQueryOutcome.noMatch => Icons.search_off,
      SourceQueryOutcome.unsupported => Icons.remove_circle_outline,
      _ =>
        report.failureKind == SourceFailureKind.rateLimited
            ? Icons.hourglass_top
            : Icons.info_outline,
    };
    final status = switch (report.outcome) {
      SourceQueryOutcome.success => '找到 ${report.candidateCount} 项候选',
      SourceQueryOutcome.noMatch => '未找到匹配',
      SourceQueryOutcome.unsupported => '不支持本次查询内容',
      SourceQueryOutcome.partial => '已找到 ${report.candidateCount} 项候选，部分查询未完成',
      SourceQueryOutcome.failed => _failureLabel(report.failureKind),
    };
    final seconds = report.retrySeconds(now);
    final waiting = seconds > 0
        ? '${report.serverRetryAt != null && !report.serverRetryAt!.isBefore(report.retryAt!) ? '来源要求等待' : '本机暂停重试'} · $seconds 秒后可重试'
        : report.retryAt != null && failed
        ? '等待已结束，可手动重试'
        : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(icon, size: 20, color: colors.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${report.sourceName} · $status',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.onSurface,
                ),
              ),
              if (waiting != null) ...[
                const SizedBox(height: 2),
                // Do not announce every second as an accessibility live region.
                Text(
                  waiting,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

String _failureLabel(SourceFailureKind? kind) => switch (kind) {
  SourceFailureKind.rateLimited => '请求受限（429）',
  SourceFailureKind.serverError => '服务暂不可用',
  SourceFailureKind.timeout => '连接超时',
  SourceFailureKind.network => '网络连接失败',
  SourceFailureKind.invalidResponse => '返回内容异常',
  SourceFailureKind.identityConflict => '录音信息不一致',
  SourceFailureKind.accessDenied => '来源拒绝访问',
  SourceFailureKind.httpError => '请求失败',
  SourceFailureKind.unknown || null => '查询未完成',
};
