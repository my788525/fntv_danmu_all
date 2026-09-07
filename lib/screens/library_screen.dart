import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/app_state.dart';
import '../models/media_item.dart';
import '../models/play_list_item.dart';
import '../models/watch_record.dart';
import '../utils/theme.dart';
import '../widgets/continue_watching_card.dart';
import 'player_screen.dart';
import 'series_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

/// 文件夹层级导航中的一个节点。
/// [parentKey] 用于在前端重建目录树时筛选「直接子项」：
///   - '' 表示媒体库根的直接子项；
///   - 否则为某个目录条目的 guid，表示「该目录下的直接子项」。
class _NavNode {
  final String parentKey;
  final String title;
  _NavNode({required this.parentKey, required this.title});
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<MediaDbItem> _libraries = [];
  bool _loadingLibs = true;

  // 当前正在浏览的媒体库
  String? _libraryGuid;
  String? _libraryTitle;
  // 当前库拉到的全量后代（按 parent_guid 在前端分组建树）
  List<PlayListItem>? _allItems;
  // 全部「文件夹节点」：既含结果里真实存在的 Directory/TV 项，
  // 也含仅能从子项 parent_guid 推断、再用 item/{guid} 解析出名字的「虚拟文件夹」。
  Map<String, PlayListItem> _folderNodes = {};
  bool _loadingTree = false;

  // 导航栈：栈底 = 库根，越往上层级越深
  final List<_NavNode> _stack = [];

  AppState get _app => context.read<AppState>();

  @override
  void initState() {
    super.initState();
    _loadLibraries();
  }

  Future<void> _loadLibraries() async {
    setState(() => _loadingLibs = true);
    // 原「首页」的继续观看记录由媒体库承载：进入即拉取服务端播放记录
    unawaited(_app.fetchServerPlayList());
    try {
      final resp = await _app.api.getMediaDbList();
      if (resp['code'] == 0 && resp['data'] != null) {
        _libraries = (resp['data'] as List)
            .map((e) => MediaDbItem.fromJson(e))
            .toList();
      }
    } catch (e) {
      debugPrint('loadLibraries error: $e');
    }
    if (mounted) setState(() => _loadingLibs = false);
  }

  /// 进入某个媒体库：拉全量后代、解析虚拟文件夹，并初始化导航栈为「库根」。
  ///
  /// FnOS 的祖先查询（ancestor_guid）会返回整个媒体库的所有后代（平铺），
  /// 但音乐库等场景下的「文件夹」节点不会出现在结果里——只能从子视频的
  /// parent_guid 得知其 guid。为此：收集所有被引用却不在结果中的 parent_guid，
  /// 用 item/{guid} 逐个解析出名字，作为「虚拟文件夹」并入目录树。
  Future<void> _openLibrary(MediaDbItem lib) async {
    setState(() {
      _libraryGuid = lib.guid;
      _libraryTitle = lib.title;
      _allItems = null;
      _folderNodes = {};
      _loadingTree = true;
      _stack
        ..clear()
        ..add(_NavNode(parentKey: '', title: lib.title));
    });
    List<PlayListItem> items;
    try {
      items = await _app.api.fetchLibraryTree(lib.guid);
    } catch (e) {
      debugPrint('openLibrary error: $e');
      items = const <PlayListItem>[];
    }
    if (!mounted) return;

    // 1) 真实目录节点（结果中已存在）
    final folderNodes = <String, PlayListItem>{};
    for (final it in items) {
      if (it.isFolder && it.guid.isNotEmpty) folderNodes[it.guid] = it;
    }
    // 2) 收集被引用但不在结果中的父 guid（虚拟文件夹）
    final present = <String>{for (final it in items) it.guid};
    final missing = <String>{};
    for (final it in items) {
      final pg = it.parentGuid ?? '';
      if (pg.isNotEmpty && !present.contains(pg)) missing.add(pg);
    }
    // 3) 并发解析虚拟文件夹的名字
    await Future.wait(missing.map((g) async {
      try {
        final resp = await _app.api.getItemInfo(g);
        final d = resp['data'];
        if (d is Map && d['guid'] != null) {
          final node = PlayListItem.fromJson(d as Map<String, dynamic>);
          if (node.guid.isNotEmpty) folderNodes[node.guid] = node;
        }
      } catch (_) {
        // 个别 guid 解析失败时忽略，不影响其余层级
      }
    }));

    if (!mounted) return;
    setState(() {
      _allItems = items;
      _folderNodes = folderNodes;
      _loadingTree = false;
    });
  }

  /// 当前节点（栈顶）的直接子项：合并「结果里的子项」与「虚拟文件夹子项」，
  /// 目录在前、视频在后。
  List<PlayListItem> _childrenOf(String parentKey) {
    if (_allItems == null) return const <PlayListItem>[];
    final libGuid = _libraryGuid ?? '';
    final presentGuids = <String>{};
    final out = <PlayListItem>[];
    for (final it in _allItems!) {
      final pg = it.parentGuid ?? '';
      // 兼容：飞牛可能用库 guid 作为库根直接视频的 parent_guid
      final effective = (parentKey == '' && pg == libGuid) ? '' : pg;
      if (effective == parentKey) {
        out.add(it);
        if (it.guid.isNotEmpty) presentGuids.add(it.guid);
      }
    }
    // 虚拟文件夹：被引用为父、但自身不在结果里
    for (final f in _folderNodes.values) {
      final pg = f.parentGuid ?? '';
      final effective = (parentKey == '' && pg == libGuid) ? '' : pg;
      if (effective == parentKey && !presentGuids.contains(f.guid)) {
        out.add(f);
      }
    }
    out.sort((a, b) {
      final af = a.isFolder ? 0 : 1;
      final bf = b.isFolder ? 0 : 1;
      if (af != bf) return af.compareTo(bf);
      return _sortKey(a).compareTo(_sortKey(b));
    });
    return out;
  }

  String _sortKey(PlayListItem it) => (it.title ?? it.tvTitle ?? '').toLowerCase();

  void _onItemTap(PlayListItem item) {
    // 剧集（TV）或季（Season）：进入「选集」页，而非直接播放
    if (item.type == 'TV' || item.type == 'Season') {
      final tvGuid = item.type == 'TV' ? item.guid : (item.parentGuid ?? '');
      final tvTitle = item.type == 'TV'
          ? (item.title ?? '')
          : (item.parentTitle ?? item.title ?? '');
      final tvPoster = item.type == 'TV' ? (item.poster ?? '') : '';
      final initialSeason = item.type == 'Season' ? item.guid : null;
      if (tvGuid.isNotEmpty) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SeriesScreen(
              tvGuid: tvGuid,
              tvTitle: tvTitle,
              tvPoster: tvPoster,
              allItems: _allItems,
              api: _app.api,
              initialSeasonGuid: initialSeason,
            ),
          ),
        );
        return;
      }
    }
    if (item.isFolder) {
      // 进入下级目录：压栈，按该目录 guid 筛选其直接子项
      setState(() => _stack.add(_NavNode(parentKey: item.guid, title: item.title ?? '')));
      return;
    }
    // 视频：直接播放，播放列表为当前层所有可播放项（顺序连播）
    final currentParentKey = _stack.isNotEmpty ? _stack.last.parentKey : '';
    final playlist = _childrenOf(currentParentKey).where((e) => e.isPlayable).toList();
    int index = playlist.indexWhere((e) => e.guid == item.guid);
    if (index < 0) {
      playlist.add(item);
      index = playlist.length - 1;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          itemGuid: item.guid,
          title: item.title ?? '',
          poster: item.poster ?? '',
          category: item.categoryLabel,
          tvTitle: item.tvTitle ?? '',
          parentGuid: item.parentGuid,
          logoUrl: '',
          playlist: playlist,
          playlistIndex: index,
        ),
      ),
    ).then((_) {
      if (mounted) _app.fetchServerPlayList();
    });
  }

  /// 返回上一级；若已在库根，则返回媒体库列表。
  void _goBack() {
    if (_stack.length > 1) {
      setState(() => _stack.removeLast());
    } else {
      setState(() {
        _libraryGuid = null;
        _libraryTitle = null;
        _allItems = null;
        _folderNodes = {};
        _stack.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_libraryGuid != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _goBack();
        },
        child: _buildBrowseView(),
      );
    }
    return _buildLibraryList();
  }

  Widget _buildLibraryList() {
    final app = context.watch<AppState>();
    final history = app.watchHistory.where((r) => !r.isNearlyFinished).toList();
    if (_loadingLibs && _libraries.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: FnTheme.danmuGreen));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 原「首页」的继续观看，移至媒体库顶部
        if (history.isNotEmpty) _buildContinueWatching(history, app),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('媒体库',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            )),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text('${_libraries.length} 个资料库',
            style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await _loadLibraries();
              await _app.fetchServerPlayList();
            },
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 3.4,
              ),
              itemCount: _libraries.length,
              itemBuilder: (_, i) {
                final lib = _libraries[i];
                return Card(
                  margin: EdgeInsets.zero,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _openLibrary(lib),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            width: 52, height: 52,
                            decoration: BoxDecoration(
                              color: FnTheme.danmuGreen.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              lib.category == 'TV' ? Icons.tv_rounded : Icons.movie_rounded,
                              color: FnTheme.danmuGreen,
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(lib.title,
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                const SizedBox(height: 3),
                                Text(lib.category ?? '影视库',
                                  style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right_rounded, color: FnTheme.textMuted),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 继续观看：横向滚动卡片列表（源自服务端播放记录）。
  Widget _buildContinueWatching(List<WatchRecord> history, AppState app) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              const Icon(Icons.play_circle_outline, color: FnTheme.danmuGreen, size: 20),
              const SizedBox(width: 6),
              const Text('继续观看',
                style: TextStyle(
                  color: FnTheme.danmuGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                )),
            ],
          ),
        ),
        SizedBox(
          height: 114,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: history.length,
            itemBuilder: (_, i) => ContinueWatchingCard(
              record: history[i],
              imageUrl: app.api.getImageUrl(history[i].poster),
              onTap: () => _onWatchRecordTap(history[i]),
            ),
          ),
        ),
      ],
    );
  }

  /// 点击继续观看卡片：跳转到对应条目并续播。
  Future<void> _onWatchRecordTap(WatchRecord record) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          itemGuid: record.guid,
          title: record.title,
          tvTitle: record.tvTitle ?? '',
          episodeNumber: record.episodeNumber,
          poster: record.poster ?? '',
          category: record.libraryName ?? '',
          seekTs: record.ts,
          duration: record.duration,
          parentGuid: record.parentGuid,
        ),
      ),
    );
    // 返回后刷新继续观看列表（进度/已看完可能变化）
    if (mounted) _app.fetchServerPlayList();
  }

  Widget _buildBrowseView() {
    final currentParentKey = _stack.isNotEmpty ? _stack.last.parentKey : '';
    final items = _childrenOf(currentParentKey);
    return Column(
      children: [
        // 顶栏：返回 + 当前层级标题 + 项计数
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _goBack,
              ),
              Expanded(
                child: Text(
                  _stack.isNotEmpty ? _stack.last.title : (_libraryTitle ?? ''),
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_allItems != null)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text('${items.length} 项',
                    style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loadingTree
              ? const Center(child: CircularProgressIndicator(color: FnTheme.danmuGreen))
              : _allItems == null
                  ? const SizedBox.shrink()
                  : items.isEmpty
                      ? const Center(child: Text('暂无内容', style: TextStyle(color: Colors.grey)))
                      : _buildTreeList(items),
        ),
      ],
    );
  }

  /// 当前层：文件夹分区在前、视频分区在后。
  Widget _buildTreeList(List<PlayListItem> items) {
    final folders = items.where((e) => e.isFolder).toList();
    final files = items.where((e) => !e.isFolder).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [
        if (folders.isNotEmpty) ...[
          _sectionTitle('文件夹 (${folders.length})'),
          ...folders.map(_folderRow),
          const SizedBox(height: 8),
        ],
        if (files.isNotEmpty) ...[
          _sectionTitle('视频 (${files.length})'),
          ...files.map(_fileRow),
        ],
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
      child: Text(text,
        style: const TextStyle(
          color: FnTheme.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        )),
    );
  }

  Widget _folderRow(PlayListItem item) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _onItemTap(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.folder_rounded, color: FnTheme.danmuGreen, size: 26),
              const SizedBox(width: 14),
              Expanded(
                child: Text(item.title ?? '未命名',
                  style: const TextStyle(fontSize: 15, color: FnTheme.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              ),
              Text(item.categoryLabel,
                style: const TextStyle(color: FnTheme.textMuted, fontSize: 12)),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, color: FnTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileRow(PlayListItem item) {
    final url = _app.api.getImageUrl(item.poster, width: 200);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _onItemTap(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 60,
                  height: 36,
                  child: url.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: url,
                          httpHeaders: _app.api.imageHeaders,
                          fit: BoxFit.cover,
                          width: 60,
                          height: 36,
                          fadeInDuration: Duration.zero,
                          fadeOutDuration: Duration.zero,
                          placeholder: (_, __) => Container(color: const Color(0xFF2A2A2A)),
                          errorWidget: (_, __, ___) => const Icon(
                            Icons.movie_outlined, color: Colors.grey, size: 20),
                        )
                      : const Icon(Icons.movie_outlined, color: Colors.grey, size: 20),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(item.title ?? '未命名',
                      style: const TextStyle(fontSize: 15, color: FnTheme.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(item.categoryLabel,
                      style: const TextStyle(color: FnTheme.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              const Icon(Icons.play_arrow_rounded, color: FnTheme.danmuGreen),
            ],
          ),
        ),
      ),
    );
  }
}
