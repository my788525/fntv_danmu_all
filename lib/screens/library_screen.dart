import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../models/media_item.dart';
import '../models/play_list_item.dart';

import '../utils/theme.dart';
import '../widgets/media_card.dart';

import 'player_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<MediaDbItem> _libraries = [];
  bool _loading = true;
  String? _browseGuid;
  String? _browseTitle;
  List<PlayListItem>? _browseItems;

  @override
  void initState() {
    super.initState();
    _loadLibraries();
  }

  AppState get _app => context.read<AppState>();

  Future<void> _loadLibraries() async {
    setState(() { _loading = true; _browseGuid = null; _browseItems = null; });
    try {
      final resp = await _app.api.getMediaDbList();
      if (resp['code'] == 0 && resp['data'] != null) {
        _libraries = (resp['data'] as List).map((e) => MediaDbItem.fromJson(e)).toList();
      }
    } catch (e) {
      debugPrint('loadLibraries error: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fetchItems(String guid, String title) async {
    setState(() { _loading = true; _browseGuid = guid; _browseTitle = title; });
    try {
      // 分页累加：fnOS 单个媒体库影片数可能达数百，必须翻页取满 total，
      // 否则仅显示首屏 50 条（旧 page_size=50 未翻页导致「电影180+只显示50部」）。
      final all = <PlayListItem>[];
      int page = 1;
      const pageSize = 200;
      while (true) {
        final resp = await _app.api.getItemList({
          'ancestor_guid': guid,
          'tags': {'type': ['Movie', 'TV', 'Directory', 'Video']},
          'exclude_grouped_video': 1,
          'sort_type': 'DESC',
          'sort_column': 'create_time',
          'page': page,
          'page_size': pageSize,
        });
        if (resp['code'] != 0 || resp['data'] == null || resp['data']['list'] == null) break;
        final list = (resp['data']['list'] as List)
            .map((e) => PlayListItem.fromJson(e))
            .toList();
        all.addAll(list);
        final total = (resp['data']['total'] ?? 0).toInt();
        // 取空、或已取满、或已超出 total 则停止翻页
        if (list.isEmpty || all.length >= total) break;
        page++;
      }
      _browseItems = all;
    } catch (e) {
      debugPrint('fetchItems error: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _onItemTap(PlayListItem item) async {
    if (item.isFolder) {
      // 文件夹/剧集容器：进入下级目录浏览
      _fetchItems(item.guid, item.title ?? '');
      return;
    }
    // 文件夹模式：可播放项直接播放，跳过详情页；
    // 将当前目录下所有同级可播放项构建为播放列表，按顺序自动连播、播完循环回头部。
    final playlist = (_browseItems?.where((e) => e.isPlayable).toList()) ?? <PlayListItem>[item];
    int index = playlist.indexWhere((e) => e.guid == item.guid);
    if (index < 0) {
      playlist.add(item);
      index = playlist.length - 1;
    }
    await Navigator.push(context, MaterialPageRoute(
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
    ));
    if (mounted) _app.fetchServerPlayList();
  }

  int _calcColumns(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w > 1200) return 7;
    if (w > 900) return 5;
    if (w > 600) return 4;
    return 3;
  }

  @override
  Widget build(BuildContext context) {
    if (_browseGuid != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) {
            setState(() { _browseGuid = null; _browseItems = null; });
          }
        },
        child: _buildBrowseView(),
      );
    }
    return _buildLibraryList();
  }

  Widget _buildLibraryList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: FnTheme.danmuGreen));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('媒体库', style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.bold,
          )),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text('${_libraries.length} 个资料库',
            style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
        ),
        // Library list
        Expanded(
          child: RefreshIndicator(
            onRefresh: _loadLibraries,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _libraries.length,
              itemBuilder: (_, i) {
                final lib = _libraries[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => _fetchItems(lib.guid, lib.title),
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

  Widget _buildBrowseView() {
    return Column(
      children: [
        // Back bar
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => setState(() { _browseGuid = null; _browseItems = null; }),
              ),
              Text(_browseTitle ?? '', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              if (_browseItems != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Text('${_browseItems!.length} 项',
                    style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
                ),
            ],
          ),
        ),
        Expanded(
          child: _browseItems == null
              ? const Center(child: CircularProgressIndicator(color: FnTheme.danmuGreen))
              : _browseItems!.isEmpty
                  ? const Center(child: Text('暂无内容', style: TextStyle(color: Colors.grey)))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: _calcColumns(context),
                        childAspectRatio: 0.50,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: _browseItems!.length,
                      itemBuilder: (_, i) => MediaCard(
                        item: _browseItems![i],
                        imageUrl: _app.api.getImageUrl(_browseItems![i].poster),
                        onTap: () => _onItemTap(_browseItems![i]),
                        showTitle: true,
                        expandWidth: true,
                      ),
                    ),
        ),
      ],
    );
  }
}
