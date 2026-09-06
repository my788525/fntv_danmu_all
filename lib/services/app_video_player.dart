import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/stream_response.dart';
import 'player_adapter.dart';

/// 播放页统一视频控制器（MPV / Exo 共用接口）
abstract class AppVideoPlayer implements PlayerAdapter {
  ValueNotifier<Duration> get positionNotifier;
  ValueNotifier<int> get networkSpeedBps;

  PlayerCoreType get coreType;
  bool get mpvSubtitleActive;

  void Function(Duration lastStable)? onPositionRegression;

  /// 播放自然结束（播放到结尾）回调。由播放器实现监听底层完成事件后触发，
  /// 用于自动连播（文件夹 playlist / 剧集 episode）下一项。
  void Function()? onCompleted;

  Future<void> resumeAfterPlay(Duration target);
  Future<void> applyInitialAudioIfNeeded({
    List<AudioStreamInfo>? audioStreams,
    int preferredListIndex,
  });
  Future<void> setAudioTrackByInfo({
    required int listIndex,
    AudioStreamInfo? info,
  });
  Future<void> setSubtitleTrack(int listIndex);
  Future<bool> enableEmbeddedSubtitleDeferred({
    required int listIndex,
    SubtitleStreamInfo? info,
    Duration delay,
  });

  Widget buildVideo({
    bool subtitleVisible,
    double subtitleSize,
    double subtitleOutline,
    bool subtitleBackground,
    Color subtitleColor,
    double subtitleWeight,
  });
}
