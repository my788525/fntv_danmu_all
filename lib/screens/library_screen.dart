import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
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

  /// 媒体库查看方式：false = 海报墙（原有默认行为），true = 文件夹
  bool _folderView = false;
  static const _kFolderViewKey = 'library_folder_view';

  @override
  void initState() {
    super.initState();
    _loadFolderView();
    _loadLibraries();
  }

  AppState get _app => context.read<AppState>();

  /// 恢复上次选择的媒体库查看方式
  Future<void> _loadFolderView() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_kFolderViewKey) ?? false;
      if (!mounted) return;
      setState(() => _folderView = saved);
    } catch (e) {
      debugPrint('loadFolderView error: $e');
    }
  }

  /// 切换查看方式并持久化；若正在浏览某个库，立即按新方式重新拉取
  Future<void> _setFolderView(bool value) async {
    if (_folderView == value) return;
    setState(() => _folderView = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kFolderViewKey, value);
    } catch (e) {
      debugPrint('saveFolderView error: $e');
    }
    final guid = _browseGuid;
    if (guid != null) {
      await _fetchItems(guid, _browseTitle ?? '');
    }
  }

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
      // 文件夹方式：强制按目录层级逐级浏览（parent_guid）。
      // 海报方式：沿用原有自动判定——顶层媒体库源走 ancestor_guid，
      // fv_ 嵌套目录走 parent_guid，任一为空自动回退另一种形态
      // （参照 fnos_tv_danmu v1.2.9 修复「暂无内容」）。
      _browseItems = _folderView
          ? await _app.api.fetchItemsInContainer(guid, forceParent: true)
          : await _app.api.fetchItemsInContainer(guid);
    } catch (e) {
      debugPrint('fetchItems error: $e');
      _browseItems = const <PlayListItem>[];
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
          child: Row(
            children: [
              Text('${_libraries.length} 个资料库',
                style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
              const Spacer(),
              _buildViewModeSwitch(),
            ],
          ),
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

  /// 查看方式切换（海报 / 文件夹）
  Widget _buildViewModeSwitch() {
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: FnTheme.cardBg,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _viewModeChip(
            icon: Icons.grid_view_rounded,
            label: '海报',
            selected: !_folderView,
            onTap: () => _setFolderView(false),
          ),
          _viewModeChip(
            icon: Icons.folder_outlined,
            label: '文件夹',
            selected: _folderView,
            onTap: () => _setFolderView(true),
          ),
        ],
      ),
    );
  }

  Widget _viewModeChip({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? FnTheme.danmuGreen : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15,
              color: selected ? Colors.black : FnTheme.textSecondary),
            const SizedBox(width: 5),
            Text(label,
              style: TextStyle(
                fontSize: 13,
                color: selected ? Colors.black : FnTheme.textSecondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              )),
          ],
        ),
      ),
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
              Expanded(
                child: Text(_browseTitle ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              ),
              if (_browseItems != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('${_browseItems!.length} 项',
                    style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
                ),
              _buildViewModeSwitch(),
              const SizedBox(width: 8),
            ],
          ),
        ),
        Expanded(
          child: _browseItems == null
              ? const Center(child: CircularProgressIndicator(color: FnTheme.danmuGreen))
              : _browseItems!.isEmpty
                  ? const Center(child: Text('暂无内容', style: TextStyle(color: Colors.grey)))
                  : _folderView
                      ? _buildFolderList()
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

  /// 文件夹方式：目录在上、可播放视频在下，逐层进入
  Widget _buildFolderList() {
    final folders = _browseItems!.where((e) => e.isFolder).toList();
    final files = _browseItems!.where((e) => !e.isFolder).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [
        if (folders.isNotEmpty) ...[
          _buildSectionTitle('文件夹 (${folders.length})'),
          ...folders.map(_buildFolderRow),
          const SizedBox(height: 8),
        ],
        if (files.isNotEmpty) ...[
          _buildSectionTitle('视频 (${files.length})'),
          ...files.map(_buildFileRow),
        ],
      ],
    );
  }

  Widget _buildSectionTitle(String text) {
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

  Widget _buildFolderRow(PlayListItem item) {
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

  Widget _buildFileRow(PlayListItem item) {
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
