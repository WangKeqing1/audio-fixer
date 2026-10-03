import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/audio_field_validation.dart';
import '../../core/models/audio_track.dart';
import '../../core/services/sources/track_search.dart';
import '../../shared/widgets/notice_panel.dart';
import '../../shared/widgets/track_artwork.dart';
import '../tasks/candidate_review_page.dart';
import 'library_controller.dart';

/// Edits produce a reviewable candidate set; this page never writes audio.
class MetadataEditorPage extends StatefulWidget {
  const MetadataEditorPage({
    super.key,
    required this.track,
    required this.controller,
    this.queryOnly = false,
    this.initialValues = const {},
  });

  final AudioTrack track;
  final LibraryController controller;
  final bool queryOnly;
  final Map<AudioField, String> initialValues;

  @override
  State<MetadataEditorPage> createState() => _MetadataEditorPageState();
}

class _MetadataEditorPageState extends State<MetadataEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _selected = <AudioField>{};
  final _values = <AudioField, TextEditingController>{};
  final _searchValues = <AudioField, TextEditingController>{};
  late final Set<AudioField> _onlineFields;
  late final TrackSearch _search;
  String? _artwork;
  String? _notice;
  bool _working = false;
  bool _pickingArtwork = false;

  @override
  void initState() {
    super.initState();
    for (final field in AudioField.values) {
      if (field == AudioField.artwork) continue;
      _values[field] = TextEditingController(
        text: widget.queryOnly
            ? widget.track.valueOf(field)
            : widget.initialValues[field] ?? widget.track.valueOf(field),
      );
    }
    if (!widget.queryOnly && widget.initialValues.isNotEmpty) {
      _artwork = widget.initialValues[AudioField.artwork];
      _notice = '已恢复上次编辑内容。请核对当前标签，重新勾选需要保留的修改。';
    }
    _search = TrackSearch.fromTrack(widget.track);
    final searchValues = {
      AudioField.title: _search.title,
      AudioField.artist: _search.artist,
      AudioField.album: _search.album,
    };
    for (final field in searchValues.keys) {
      _searchValues[field] = TextEditingController(text: searchValues[field]);
    }
    _onlineFields = widget.controller.completion.sources
        .expand((source) => source.supportedFields)
        .where((field) => !_isInstrumentalLyrics(field))
        .toSet();
    if (widget.queryOnly) _selected.addAll(_onlineFields);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final value in [..._values.values, ..._searchValues.values]) {
      value.dispose();
    }
    super.dispose();
  }

  bool _isInstrumentalLyrics(AudioField field) =>
      widget.track.isInstrumental && field == AudioField.lyrics;

  bool get _stale {
    final current = widget.controller.trackById(widget.track.id);
    return current == null ||
        !current.detailsLoaded ||
        current.requiresTagRefresh ||
        widget.track.requiresTagRefresh ||
        current.readError != null ||
        current.dateModifiedMs != widget.track.dateModifiedMs ||
        current.sizeBytes != widget.track.sizeBytes ||
        current.contentUri != widget.track.contentUri ||
        current.localPath != widget.track.localPath ||
        current.artworkSha256 != widget.track.artworkSha256 ||
        current.isInstrumental != widget.track.isInstrumental ||
        AudioField.values.any(
          (field) => current.valueOf(field) != widget.track.valueOf(field),
        );
  }

  String _value(AudioField field) => field == AudioField.artwork
      ? _artwork ?? ''
      : _values[field]!.text.trim();

  bool _changed(AudioField field) =>
      hasText(_value(field)) &&
      _value(field) != (widget.track.valueOf(field)?.trim() ?? '');

  Map<AudioField, String> get _changes => {
    for (final field in _selected)
      if (_changed(field) && !_isInstrumentalLyrics(field))
        field: _value(field),
  };

  void _showNotice(String? message) {
    setState(() => _notice = message);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickArtwork() async {
    if (_working || _pickingArtwork || _stale) return;
    final route = ModalRoute.of(context);
    setState(() {
      _pickingArtwork = true;
      _notice = null;
    });
    final revision = widget.controller.noticeRevision;
    try {
      final value = await widget.controller.pickArtwork();
      if (!mounted || route?.isCurrent != true || _stale) return;
      if (value != null) {
        setState(() {
          _artwork = value;
          // Choosing an image does not approve replacing the current cover.
          _selected.remove(AudioField.artwork);
        });
      } else if (widget.controller.noticeRevision != revision) {
        _showNotice(widget.controller.notice);
      }
    } catch (_) {
      if (mounted && route?.isCurrent == true) {
        _showNotice('封面未能读取，请选择有效的 JPEG 或 PNG 图片。');
      }
    } finally {
      if (mounted) setState(() => _pickingArtwork = false);
    }
  }

  Future<void> _submit() async {
    final controller = widget.controller;
    if (_working || _pickingArtwork || !controller.canOperate || _stale) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final changes = _changes;
    if (widget.queryOnly ? _selected.isEmpty : changes.isEmpty) return;
    if (!widget.queryOnly) {
      final error = validateAudioFieldChanges(widget.track, changes);
      if (error != null) {
        _showNotice(error);
        return;
      }
    }
    final route = ModalRoute.of(context);
    final previousTask = controller.taskForTrack(widget.track.id);
    setState(() {
      _working = true;
      _notice = null;
    });
    try {
      final task = widget.queryOnly
          ? await (() async {
              await controller.queryRepair(
                widget.track.id,
                fields: Set.unmodifiable(_selected),
                searchTitle: _searchValues[AudioField.title]!.text.trim(),
                searchArtist: _searchValues[AudioField.artist]!.text.trim(),
                searchAlbum: _searchValues[AudioField.album]!.text.trim(),
              );
              final result = controller.taskForTrack(widget.track.id);
              return result?.createdAt == previousTask?.createdAt
                  ? null
                  : result;
            })()
          : await controller.createManualRepair(widget.track.id, changes);
      if (!mounted || route?.isCurrent != true) return;
      if (task != null &&
          task.suggestions.isNotEmpty &&
          controller.isTaskCurrent(task)) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) =>
                CandidateReviewPage(task: task, controller: controller),
          ),
        );
      } else {
        _showNotice(task?.message ?? controller.notice ?? '尚未生成候选资料，请检查选择后重试。');
      }
    } catch (_) {
      if (mounted && route?.isCurrent == true) {
        _showNotice('操作未完成，请检查输入后重试。文件尚未修改。');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final enabled =
          controller.canOperate &&
          !_working &&
          !_pickingArtwork &&
          !_stale &&
          (widget.queryOnly || controller.canExportTrack(widget.track));
      final count = widget.queryOnly ? _selected.length : _changes.length;
      return Scaffold(
        appBar: AppBar(title: Text(widget.queryOnly ? '查询修复资料' : '编辑元数据与封面')),
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Form(
                key: _formKey,
                child: ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      widget.track.displayTitle,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.queryOnly
                          ? '选择要查询的项目，已有资料也可以重新匹配。查询后逐项查看旧值与新值，再决定是否保存。'
                          : '修改需要修复的内容，再勾选对应项目进入确认页。未勾选的标签保留；留空不会删除已有内容。',
                    ),
                    const SizedBox(height: 12),
                    const Text('支持常用标准标签（Tag）。其他自定义标签保持原样，暂不提供编辑。'),
                    const SizedBox(height: 16),
                    if (widget.track.tagReadWarnings.isNotEmpty) ...[
                      NoticePanel(
                        icon: Icons.info_outline,
                        title: '已有标签的读取提示',
                        message: widget.track.tagReadWarnings.join('\n'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_stale) ...[
                      const NoticePanel(
                        icon: Icons.refresh,
                        title: '歌曲资料已变化',
                        message: '请返回歌曲资料页重新打开编辑，避免用旧值覆盖新资料。',
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (_notice != null) ...[
                      NoticePanel(
                        icon: Icons.info_outline,
                        title: '处理结果',
                        message: _notice!,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (!controller.canSaveOriginalTrack(widget.track)) ...[
                      NoticePanel(
                        icon: Icons.info_outline,
                        title: '保存能力',
                        message: controller.canExportTrack(widget.track)
                            ? '此来源暂不支持原位保存，确认后可选择导出副本。'
                            : '${widget.track.extension} 当前可查看标签与查询候选。安全写入支持 MP3、FLAC 和 M4A/MP4；此格式或来源暂不支持编辑保存。',
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (widget.queryOnly)
                      ..._queryFields(enabled)
                    else ...[
                      _artworkEditor(enabled),
                      const SizedBox(height: 16),
                      for (final field in AudioField.values)
                        if (field != AudioField.artwork)
                          _textEditor(field, enabled),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: _working
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(controller.progress ?? '正在生成候选…'),
                      if (controller.isCompleting)
                        TextButton.icon(
                          onPressed: controller.completionStopRequested
                              ? null
                              : controller.stopCompletion,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('停止查询'),
                        ),
                    ],
                  )
                : FilledButton.icon(
                    key: const ValueKey('review-metadata-changes'),
                    onPressed: enabled && count > 0 ? _submit : null,
                    icon: Icon(
                      widget.queryOnly
                          ? Icons.search
                          : Icons.fact_check_outlined,
                    ),
                    label: Text(
                      widget.queryOnly
                          ? '查询所选 $count 项资料'
                          : !controller.canExportTrack(widget.track)
                          ? '此格式暂不支持编辑保存'
                          : '检查 $count 项修改',
                    ),
                  ),
          ),
        ),
      );
    },
  );

  List<Widget> _queryFields(bool enabled) => [
    Text('匹配线索', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 8),
    const Text('歌名、歌手有误时可在这里纠正搜索词。这些搜索词不会直接写入标签。'),
    if (_search.normalizationNotes.isNotEmpty) ...[
      const SizedBox(height: 12),
      NoticePanel(
        icon: Icons.manage_search,
        title: '已整理搜索线索',
        message:
            '${_search.normalizationNotes.join('\n')}\n请核对下方搜索词，原标签与文件名保持原样。',
      ),
    ],
    for (final field in _searchValues.keys)
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextFormField(
          key: ValueKey('search-${field.name}'),
          controller: _searchValues[field],
          enabled: enabled,
          decoration: InputDecoration(
            labelText: '搜索${field.label}',
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    const SizedBox(height: 24),
    Text('要查询的项目', style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 8),
    for (final field in AudioField.values)
      CheckboxListTile(
        key: ValueKey('query-${field.name}'),
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        subtitle: Text(
          _isInstrumentalLyrics(field)
              ? '纯音乐 · 跳过歌词查询与翻译'
              : !_onlineFields.contains(field)
              ? '暂无在线来源，可在编辑页手动修复'
              : hasText(widget.track.valueOf(field))
              ? '已有资料 · 可查询替换候选'
              : '缺失 · 查询补全候选',
        ),
        value: _selected.contains(field),
        onChanged: enabled && _onlineFields.contains(field)
            ? (checked) => setState(
                () => checked == true
                    ? _selected.add(field)
                    : _selected.remove(field),
              )
            : null,
        controlAffinity: ListTileControlAffinity.leading,
      ),
  ];

  Widget _textEditor(AudioField field, bool enabled) {
    final changed = _changed(field);
    final instrumental = _isInstrumentalLyrics(field);
    final selected = changed && _selected.contains(field);
    final numeric = field.isNumeric;
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            key: ValueKey('select-${field.name}'),
            title: Text(field.label),
            subtitle: Text(
              instrumental
                  ? '纯音乐 · 保留现有歌词，取消纯音乐后可编辑'
                  : changed
                  ? hasText(widget.track.valueOf(field))
                        ? '勾选后将替换已有${field.label}'
                        : '勾选后补入${field.label}'
                  : '修改内容后可勾选',
            ),
            value: selected,
            onChanged: enabled && changed && !instrumental
                ? (checked) => setState(
                    () => checked == true
                        ? _selected.add(field)
                        : _selected.remove(field),
                  )
                : null,
            controlAffinity: ListTileControlAffinity.leading,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: TextFormField(
              key: ValueKey('edit-${field.name}'),
              controller: _values[field],
              enabled: enabled && !instrumental,
              keyboardType: numeric
                  ? TextInputType.number
                  : field == AudioField.lyrics
                  ? TextInputType.multiline
                  : TextInputType.text,
              minLines: field == AudioField.lyrics ? 4 : 1,
              maxLines: field == AudioField.lyrics
                  ? 10
                  : field.name == 'comment'
                  ? 4
                  : 1,
              decoration: InputDecoration(
                labelText: field.label,
                border: const OutlineInputBorder(),
              ),
              validator: (value) =>
                  selected ? validateAudioFieldValue(field, value ?? '') : null,
              onChanged: (_) => setState(() {
                if (!_changed(field)) _selected.remove(field);
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _artworkEditor(bool enabled) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('封面', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Wrap(
            spacing: 20,
            runSpacing: 16,
            children: [
              Column(
                children: [
                  const Text('当前封面'),
                  const SizedBox(height: 8),
                  TrackArtwork(path: widget.track.artworkPath, size: 120),
                ],
              ),
              if (_artwork != null)
                Column(
                  children: [
                    const Text('新封面'),
                    const SizedBox(height: 8),
                    _LocalArtwork(value: _artwork!),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const ValueKey('pick-artwork'),
            onPressed: enabled ? _pickArtwork : null,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(_pickingArtwork ? '正在读取封面…' : '选择本机封面'),
          ),
          const Text('JPEG / PNG，最大 10 MB。取消选择会保留上一次选中的封面。'),
          const SizedBox(height: 8),
          const Text('替换正面封面并保留其他类型图片；M4A/MP4 替换首张封面，保留其余图片。'),
          CheckboxListTile(
            key: const ValueKey('select-artwork'),
            contentPadding: EdgeInsets.zero,
            value:
                _changed(AudioField.artwork) &&
                _selected.contains(AudioField.artwork),
            title: Text(
              hasText(widget.track.artworkPath) ? '将替换已有封面' : '补入新封面',
            ),
            onChanged: enabled && _changed(AudioField.artwork)
                ? (checked) => setState(
                    () => checked == true
                        ? _selected.add(AudioField.artwork)
                        : _selected.remove(AudioField.artwork),
                  )
                : null,
            controlAffinity: ListTileControlAffinity.leading,
          ),
        ],
      ),
    ),
  );
}

class _LocalArtwork extends StatelessWidget {
  const _LocalArtwork({required this.value});
  final String value;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'file' ||
        uri.host.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return const SizedBox(
        width: 120,
        height: 120,
        child: Center(child: Text('封面地址不可用')),
      );
    }
    return Image.file(
      File.fromUri(uri),
      width: 120,
      height: 120,
      fit: BoxFit.contain,
      semanticLabel: '所选本机封面',
      errorBuilder: (_, _, _) => const SizedBox(
        width: 120,
        height: 120,
        child: Center(child: Text('封面预览加载失败')),
      ),
    );
  }
}
