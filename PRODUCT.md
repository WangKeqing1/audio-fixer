# Audio Fixer

<!-- impeccable:product-schema 1 -->

## Platform

android

## Stack

用户指定 Flutter；Dart 实现业务层，保留标准 Kotlin Android 宿主。

## Product Purpose

自动补全音频文件的元数据、歌词和封面。本次交付范围是最基础的应用框架。

## Capabilities and Constraints

- 默认读取 Android 系统音乐库；首次请求音乐和音频权限，授权后自动加载，返回应用和点击刷新时重新查询。
- 已有标签读取、缺失信息检查、歌曲详情、补全任务入口、设置。
- 已接入 MusicBrainz 音乐资料、LRCLIB 歌词、Cover Art Archive 封面查询，候选保留来源与匹配说明。
- 当前按歌名、歌手、专辑、时长筛选候选；候选写入、原文件标签修改、全盘目录扫描和后台任务是后续范围。
- 界面不将未实现的在线功能显示为成功。

## Working Assumptions

- 暂用项目目录对应的名称 Audio Fixer，界面使用简体中文。
- 用户明确要求默认使用系统音乐库，不以手选导入作为使用前提。
- 系统音频以 content URI 标识，列表查询不复制音频；详情读取使用临时副本，读取结束后清理。
- 本地保存索引和封面缓存，原始音频留在原位置；旧版本已导入的私有副本保留。
- 基础框架采用 Material 3 原生交互；以上是当前实现选择，可在后续调整。
