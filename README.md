# Audio Fixer

使用 Flutter 构建的 Android 音频资料整理工具。用于检查音频标签、查询缺失资料，并逐项确认后导出带有新标签的音频副本。当前版本 0.2.0，默认保留原文件。

## 已实现

- 默认读取 Android MediaStore 系统音乐库，授权后自动显示歌曲，无需手选导入。
- Android 13+ 请求 `READ_MEDIA_AUDIO`，旧版使用 `READ_EXTERNAL_STORAGE`；拒绝后显示授权入口，永久拒绝时引导系统设置。
- 进入应用、返回前台和点击刷新时同步系统索引中的歌曲；列表以 content URI 标识原文件，不复制整库音频。
- 打开详情时按需读取临时副本，读取结束后清理；文件变化后重新检查标签。
- 在独立 isolate 读取已有歌名、歌手、专辑、年份、时长、内嵌歌词和封面。
- 音乐库、搜索、待补全/读取异常筛选、歌曲详情。
- 补全任务入口、各项目开关、任务状态和候选信息模型。
- MusicBrainz 元数据、LRCLIB 歌词、Cover Art Archive 封面真实在线查询；候选带来源和匹配依据。
- 歌词/封面预览、逐首保存任务、失败重查、批量查询前确认、停止后续查询、设置中的数据源连接测试。
- 候选逐项确认，MP3、FLAC、M4A/MP4 写入新副本；读取校验所选标签及已有常用标签、核对编码音频数据摘要，再通过 Android 系统保存弹窗保存新文件。
- 分离「待检查」「待补全」「读取异常」状态；刷新失败保留上次列表并显示重试提示；搜索歌名、歌手、专辑和文件名。
- 本地 JSON 持久化、中文界面、深浅主题、手机导航栏与宽屏导航轨。

标签能否读取取决于实际文件格式和标签编码。未检查的文件不会误报为缺失；读取失败会显示「读取异常」。系统索引为空、权限未授权和查询失败分别呈现，应用不会填充演示歌曲。

当前按需标签读取的单文件上限为 512 MiB，超限会明确提示；歌曲仍可出现在系统音乐库列表中。

## 本轮边界

在线查询已接入三个公开服务：MusicBrainz、LRCLIB、Cover Art Archive，无需配置 API Key。候选需要逐项确认后才可写入新副本；不会自动覆盖原文件。尚未实现直接覆盖原音频、全盘扫描和系统后台调度。`CompletionService` 只查询候选，不修改音频；独立 `SafeAudioCopyExporter` 负责复制、填入缺失项、核对标签与音频数据、保存。第三方资料缺失、同名版本无法区分、网络错误会明确显示结果。

只在发起补全、连接测试或加载所选封面预览/导出时请求在线来源。补全会发送歌名、歌手、专辑和时长，不上传音频。MusicBrainz 请求间隔至少 1.1 秒，其他请求至少间隔 400 毫秒；HTTP 429/503 的 Retry-After 会限制后续请求。短时故障可以稍后重试，停止批量任务会等待当前歌曲处理结束并保留已完成结果。

只显示系统媒体索引中标记为音乐的非空音频，未被系统识别、处于回收站或其他应用私有目录中的文件不在列表内。应用不会修改或删除原文件，也不申请全盘访问权限。音乐索引和封面缓存在应用内；旧版本已导入的私有副本保留，原导入流的 `Uint8List` 类型错误已修复并有回归测试。

## 运行

本项目由 Flutter 3.47.2 / Dart 3.13.2 生成。使用匹配的 Flutter SDK 和 Android SDK。

```powershell
flutter pub get
flutter devices
flutter run -d <安卓设备ID>
```

构建调试 APK：

```powershell
flutter build apk --debug
```

产物：`build/app/outputs/flutter-apk/app-debug.apk`。Android 宿主使用 Kotlin，包名暂为 `com.audiofixer.audio_fixer`。发布前应确认包名并配置正式签名；模板中的 release 签名仍为调试签名。

Windows 本地构建中遇到项目与 Pub 缓存分处不同盘符的 Kotlin 增量缓存错误，因此项目的 `android/gradle.properties` 设置了 `kotlin.incremental=false`。此项只影响 Kotlin 构建性能；同盘开发环境可在验证后移除。配置说明见 [Kotlin 官方文档](https://kotlinlang.org/docs/gradle-compilation-and-caches.html#incremental-compilation)。

## 结构

```text
lib/
  main.dart                      依赖装配与入口
  app/                           主题、中文本地化、主导航
  core/
    models/                      音频、设置、补全任务及候选模型
    services/
      device_music_library.dart  Android 系统音乐库、权限与按需文件读取
      audio_tag_reader.dart      独立 isolate 标签/歌词/封面解析
      audio_importer.dart        兼容旧导入服务与私有副本清理
      export/                    安全副本写入、音频摘要校验、系统保存
      metadata_source.dart       在线数据源适配接口
      completion_service.dart    根据开关查询缺失项，生成候选预览
      sources/                   三个在线适配器、HTTPS 请求、限流和匹配
    storage/library_store.dart   本地目录及设置持久化
  features/
    library/                     状态控制、音乐库、歌曲详情
    tasks/                       最近一次补全结果
    settings/                    补全内容、主题、数据源状态
  shared/                        公共组件与格式化
android/app/src/main/kotlin/      MediaStore、权限和 content URI 读取桥接
test/                            音乐库、权限、文件流、持久化和界面测试
```

状态管理使用 Flutter 自带 `ChangeNotifier`。系统音乐库、存储和数据源通过构造参数注入，后续可单独替换。UI 不直接读写文件或发起在线搜索。Android 接入方式依据 [官方媒体存储文档](https://developer.android.com/training/data-storage/shared/media) 和 [Android 13 音频权限说明](https://developer.android.com/about/versions/13/behavior-changes-13#granular-media-permissions)。

## 扩展在线补全服务

1. 实现 `MetadataSource`，声明 `name`、`supportedFields` 和 `lookup`。可为元数据、歌词、封面分别提供适配器。
2. 在 `sources/online_sources.dart` 的 `createOnlineSources` 中注册适配器。元数据和封面共用 `MusicBrainzCatalog`，避免同一歌曲重复检索。
3. 每条 `FieldSuggestion` 保留字段、候选值、来源链接和匹配说明。已有字段不会传入查询范围。HTTP 请求的超时为 12 秒，每个完整来源流程上限 45 秒。单个来源失败不会丢弃其他来源的候选，任务会同时说明失败来源。
4. 候选经 `CandidateReviewPage` 逐项确认后交给独立 `SafeAudioCopyExporter`，仅写入副本。新格式必须增加标签回读、编码音频摘要和独立解码测试，再加入支持列表。不要在查询适配器里修改音频。
5. Android 主清单已声明 INTERNET。HTTP 客户端只访问当前三个服务及 archive.org 的 HTTPS 地址；新增服务需明确加入地址允许列表。公开发布前应为 User-Agent 配置实际项目联系地址。

当前批处理按顺序执行并逐首保存，只保留每首歌曲最近一次任务；离开应用后的系统后台执行与进程终止续跑尚未实现。未命中不会填入占位资料，候选存在不会标为已经写入文件；导出成功独立显示「已导出副本」，不把原文件的缺失状态改成完整。

接口依据：[MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)、[MusicBrainz 限流说明](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)、[LRCLIB API](https://lrclib.net/docs)、[Cover Art Archive API](https://musicbrainz.org/doc/Cover_Art_Archive/API)。

## 验证

```powershell
flutter analyze
flutter test
```

真实网络冒烟检查（会发起只读请求，只打印候选长度和来源，不打印歌词全文）：

```powershell
dart run tool/check_online_sources.dart 'Yellow' 'Coldplay' 266 'Parachutes'
```

离线测试还覆盖来源匹配、版本/时长冲突、纯音乐、错误传播、限流、停止查询和连接测试。

测试使用自行构造的 WAV 和 `Stream<Uint8List>` 验证真实标签读取与旧导入错误修复；覆盖音乐权限、自动查询、变更失效、删除同步、查询失败保留目录、临时文件释放及旧数据兼容。界面测试覆盖自动音乐库到歌曲详情和任务流程、小屏/宽屏及大字体布局。

不同厂商媒体库、系统版本及真实音频编码的兼容性需要在相应安卓设备上验收。单元和界面测试不替代真机验证。

2026-09-26：29 项测试通过，静态检查通过，0.1.1 调试 APK 构建通过并更新到三星 SM-F9360（Android 16 / API 36）。已通过实际系统权限弹窗授权，自动加载 317 首歌曲；检查到一首真实歌曲的标签和封面读取成功，临时副本已释放。其他 Android 版本和更多编码格式尚未进行设备验证。

0.1.2 在线来源验证：64 项测试、静态检查和 APK 构建通过。终端用同一套真实适配器查询公开样例 Yellow / Coldplay / Parachutes，得到 3 个元数据字段、1 份同步歌词、1 个封面候选；封面 HTTPS 地址返回 200 image/jpeg。该 APK 已覆盖安装到 SM-F9360。联网匹配结果是候选资料，尚未写回原音频。

手机端已观察到三个来源均显示「连接测试通过」，并有更新后的真实歌曲查询记录；该歌曲歌词未匹配到候选，任务保存为 noMatch，未将未命中标记为补全成功。

导入错误回归用例：`flutter test test/local_storage_test.dart --plain-name "Android picker Uint8List stream can be saved and read"`。旧实现把 `Stream<Uint8List>` 直接 `pipe` 到 `IOSink`，发生运行时消费者类型不匹配；现在使用 `IOSink.addStream` 并在 `finally` 关闭输出流。当前 UI 主流程使用系统音乐库，不再要求手选导入。

可选：在本机生成真实 Flutter 组件的界面预览，使用明确标注的示例数据：

```powershell
$env:AUDIO_FIXER_PREVIEW_FONT = 'C:\Windows\Fonts\msyh.ttc'
flutter test tool/render_preview.dart
```

截图写入 `build/previews/`。该工具只读取本机字体，不向项目复制或分发字体文件。

## 安全导出与限制

1. 打开歌曲资料，查询缺失信息；也可以先确认数量再批量查询。
2. 在「确认候选资料」检查值、来源和匹配依据，取消不需要的字段。
3. 点击「导出音频副本」，应用在私有临时目录生成副本；已有字段不可被候选覆盖。
4. 校验已写入标签、未修改的常用标签与内嵌封面，以及 MP3 编码数据、FLAC STREAMINFO/音频帧、MP4 编码数据/解码所需采样表的摘要。校验不通过不进入保存步骤。
5. 通过系统「创建文档」弹窗选择新副本的位置；保存后再次核对完整文件摘要。取消不会修改原文件。保存失败会尝试清理不完整的新文件；个别文档提供程序可能不支持清理，需手动删除残留副本。

- 导出仅支持 MP3、FLAC、M4A/MP4。WAV、OGG 等可读取格式仍仅供检查与候选预览，不声称已修复。
- 单文件上限 512 MiB；封面仅接受可信来源的 HTTPS JPEG/PNG，最大 10 MiB。来源地址和每次跳转均需校验。
- 文件在查询后发生改变、字段已有内容或解析器无法校验时会停止导出。可刷新/重新读取再查询。
- 复杂 ID3 标记、分片/外部引用/非音频 MP4 等不能可靠校验的结构会安全拒绝。MP4 使用追加 moov 的方式保留媒体绝对偏移，副本可能变大并失去 fast-start 优化。
- 不承诺修复损坏音频、转码、自动纠正乱码或支持所有播放器私有标签。原文件始终保留，副本仍建议在常用播放器中验收。
- 导出副本出现在系统音乐库的时间取决于保存位置与设备媒体索引；不自动用副本替换原列表记录。

## 离线真实音频验证

工具会自行合成短测试音，不需要下载或分发商业音乐。安装 Python 3、FFmpeg 后运行：

```sh
python3 tool/generate_audio_fixtures.py
flutter test test/audio_fixture_test.dart --reporter expanded
```

覆盖 MP3/FLAC/M4A/WAV/OGG/Opus/AIFF、中文/日文/组合字符、无标签、封面、重复、伪装扩展名、截断/损坏与不支持的格式。导出测试以独立 FFmpeg 全量解码及编码包 SHA-256 检查前后音频一致，另用 ffprobe 核对已有标签。

可选地设置 `AUDIO_FIXER_REAL_INPUTS` 为本机测试歌曲目录，执行相同的离线副本验证。仅将自行编写的测试歌词填入缺失项；不会请求在线来源。输入歌曲和报告保存在忽略的 `build/test_samples/` 或调用者目录，不能加入版本库。

```sh
AUDIO_FIXER_REAL_INPUTS=/path/to/local/audio flutter test test/audio_fixture_test.dart --reporter expanded
python3 tool/validate_audio.py compare original.mp3 exported.mp3
```

## 主要依赖

- [file_picker](https://pub.dev/packages/file_picker)：兼容旧导入服务，当前主流程使用 MediaStore。
- [audio_metadata_reader](https://pub.dev/packages/audio_metadata_reader)：音频已有标签读取。
- [path_provider](https://pub.dev/packages/path_provider)：应用私有目录。
- [crypto](https://pub.dev/packages/crypto)：SHA-256 去重。

依赖版本由 `pubspec.lock` 固定。
