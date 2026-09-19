import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: what each download folder contains besides the video.
List<SettingsModel> get downloadSettings => [
  const SwitchModel(
    title: '保存弹幕（XML）',
    subtitle: 'B 站原始格式；在本应用中播放时按播放器当时的弹幕设置显示',
    leading: Icon(Icons.subtitles_outlined),
    setKey: SettingBoxKey.dlSaveDanmakuXml,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '保存弹幕（ASS）',
    subtitle: '固定样式，供其他播放器当字幕加载',
    leading: Icon(Icons.closed_caption_outlined),
    setKey: SettingBoxKey.dlSaveDanmakuAss,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '保存字幕（SRT）',
    subtitle: '视频有字幕时保存，每种语言一个文件',
    leading: Icon(Icons.closed_caption_outlined),
    setKey: SettingBoxKey.dlSaveSubtitle,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '保存封面',
    leading: Icon(Icons.image_outlined),
    setKey: SettingBoxKey.dlSaveCover,
    defaultVal: true,
  ),
  const SwitchModel(
    title: '保存热门评论（JSON）',
    leading: Icon(Icons.comment_outlined),
    setKey: SettingBoxKey.dlSaveComments,
    defaultVal: true,
  ),
  getVideoFilterSelectModel(
    title: '评论条数',
    suffix: '条',
    key: SettingBoxKey.dlCommentCount,
    values: [50, 100, 200, 500],
    defaultValue: 200,
    isFilter: false,
  ),
  getVideoFilterSelectModel(
    title: '每条评论附带回复数',
    suffix: '条',
    key: SettingBoxKey.dlReplyCount,
    values: [0, 3, 10, 20],
    defaultValue: 10,
    isFilter: false,
  ),
];
