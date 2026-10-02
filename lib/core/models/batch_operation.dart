enum BatchOperationKind { identify, saveOriginal, exportCopies }

enum BatchItemStatus {
  queued,
  running,
  needsReview,
  savedOriginal,
  exported,
  skipped,
  cancelled,
  failed,
}

class BatchItemResult {
  const BatchItemResult({
    required this.trackId,
    required this.trackTitle,
    this.status = BatchItemStatus.queued,
    this.message = '等待处理',
  });
  final String trackId;
  final String trackTitle;
  final BatchItemStatus status;
  final String message;
  bool get isFinished =>
      status != BatchItemStatus.queued && status != BatchItemStatus.running;
  BatchItemResult withResult(BatchItemStatus status, String message) =>
      BatchItemResult(
        trackId: trackId,
        trackTitle: trackTitle,
        status: status,
        message: message,
      );
  Map<String, Object?> toJson() => {
    'trackId': trackId,
    'trackTitle': trackTitle,
    'status': status.name,
    'message': message,
  };
  factory BatchItemResult.fromJson(Map<String, dynamic> json) =>
      BatchItemResult(
        trackId: json['trackId'] as String,
        trackTitle: json['trackTitle'] as String,
        status: BatchItemStatus.values.byName(json['status'] as String),
        message: json['message'] as String,
      );
}

/// Durable, bounded record of the latest explicit batch. Restart never resumes
/// a network request or a destructive write without another user action.
class BatchOperation {
  const BatchOperation({
    required this.kind,
    required this.items,
    this.isRunning = true,
    this.stopRequested = false,
  });
  final BatchOperationKind kind;
  final List<BatchItemResult> items;
  final bool isRunning;
  final bool stopRequested;
  int get totalCount => items.length;
  int get completedCount => items.where((item) => item.isFinished).length;
  int count(BatchItemStatus status) =>
      items.where((item) => item.status == status).length;
  int get failedCount => count(BatchItemStatus.failed);
  int get reviewCount => count(BatchItemStatus.needsReview);
  int get savedOriginalCount => count(BatchItemStatus.savedOriginal);
  int get exportedCount => count(BatchItemStatus.exported);
  int get skippedCount => count(BatchItemStatus.skipped);
  int get cancelledCount => count(BatchItemStatus.cancelled);
  double get progress => totalCount == 0 ? 0 : completedCount / totalCount;
  String get summary =>
      '共 $totalCount 首 · 已保存原文件 $savedOriginalCount · 已导出副本 $exportedCount · 待确认 $reviewCount · 跳过 $skippedCount · 已取消 $cancelledCount · 失败 $failedCount';
  BatchOperation copyWith({
    List<BatchItemResult>? items,
    bool? isRunning,
    bool? stopRequested,
  }) => BatchOperation(
    kind: kind,
    items: items ?? this.items,
    isRunning: isRunning ?? this.isRunning,
    stopRequested: stopRequested ?? this.stopRequested,
  );
  BatchOperation recoverInterrupted() => copyWith(
    isRunning: false,
    stopRequested: false,
    items: items
        .map(
          (item) => item.isFinished
              ? item
              : item.withResult(
                  BatchItemStatus.cancelled,
                  '上次处理已中断，请查看恢复提醒。核对文件后可重新选择处理；不会自动写入。',
                ),
        )
        .toList(),
  );
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'items': items.map((item) => item.toJson()).toList(),
    'isRunning': isRunning,
    'stopRequested': stopRequested,
  };
  factory BatchOperation.fromJson(Map<String, dynamic> json) => BatchOperation(
    kind: BatchOperationKind.values.byName(json['kind'] as String),
    items: (json['items'] as List)
        .map((item) => BatchItemResult.fromJson(item as Map<String, dynamic>))
        .toList(),
    isRunning: json['isRunning'] as bool,
    stopRequested: json['stopRequested'] as bool? ?? false,
  );
}
