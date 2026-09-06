import 'package:flutter/material.dart';
import '../models/play_list_item.dart';
import '../services/api_client.dart';
import '../utils/theme.dart';
import 'player_screen.dart';

/// 剧集选集页：点进一部电视剧（TV）后展示「季 + 集」网格，
/// 每集可单独播放；进入播放器时传入「季 guid」，使播放器内的
/// 选集面板与上一集/下一集切换正常工作。
///
/// 数据来源（按可靠性优先）：
///   1) 媒体库浏览时已拉全的扁平后代 [_allItems]（含 Season / Episode，
///      且 Episode.parentGuid 指向 Season、Season.parentGuid 指向 TV）；
///   2) 若扁平数据缺集，则用专用接口 getEpisodeList(季guid) 兜底；
///   3) 若扁平数据连季都没有，则先用 getSeasonList(TVguid) 取季再取集。
class SeriesScreen extends StatefulWidget {
  final String tvGuid;
  final String tvTitle;
  final String tvPoster;
  final List<PlayListItem>? allItems;
  final ApiClient api;
  final String? initialSeasonGuid;

  const SeriesScreen({
    super.key,
    required this.tvGuid,
    required this.tvTitle,
    this.tvPoster = '',
    this.allItems,
    required this.api,
    this.initialSeasonGuid,
  });

  @override
  State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  List<PlayListItem> _seasons = [];
  int _selectedSeason = 0;
  List<PlayListItem> _episodes = [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _epNum(PlayListItem e) => e.episodeNumber > 0 ? e.episodeNumber : 9999;
  int _szNum(PlayListItem s) => s.seasonNumber > 0 ? s.seasonNumber : 9999;

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final all = widget.allItems ?? const <PlayListItem>[];
      // 1) 本地扁平数据：找该剧集下的季
      final localSeasons = all
          .where((e) => e.type == 'Season' && (e.parentGuid ?? '') == widget.tvGuid)
          .toList()
        ..sort((a, b) => _szNum(a).compareTo(_szNum(b)));
      final localDirectEps = all
          .where((e) => e.type == 'Episode' && (e.parentGuid ?? '') == widget.tvGuid)
          .toList()
        ..sort((a, b) => _epNum(a).compareTo(_epNum(b)));

      if (localSeasons.isNotEmpty) {
        _seasons = localSeasons;
        final initIdx = widget.initialSeasonGuid != null
            ? localSeasons.indexWhere((s) => s.guid == widget.initialSeasonGuid)
            : 0;
        _selectedSeason = initIdx < 0 ? 0 : initIdx;
        await _loadEpisodesForSeason(_seasons[_selectedSeason], all);
        return;
      }
      if (localDirectEps.isNotEmpty) {
        // 没有季层级，直接是集
        _seasons = [];
        _episodes = localDirectEps;
        _loading = false;
        if (mounted) setState(() {});
        return;
      }

      // 2) 扁平数据里没有季/集 → 走专用接口
      await _loadViaApi();
    } catch (e) {
      _loadError = e.toString();
      debugPrint('SeriesScreen load error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadEpisodesForSeason(PlayListItem season, List<PlayListItem> all) async {
    List<PlayListItem> eps = const <PlayListItem>[];
    // 本地扁平数据优先（媒体库浏览已拉全后代，秒开零请求）
    final local = all
        .where((e) => e.type == 'Episode' && (e.parentGuid ?? '') == season.guid)
        .toList()
      ..sort((a, b) => _epNum(a).compareTo(_epNum(b)));
    if (local.isNotEmpty) {
      eps = local;
    } else {
      // 兜底：专用接口（扁平数据缺该季集时）
      try {
        final resp = await widget.api.getEpisodeList(season.guid);
        final data = resp['data'];
        if (data is List) {
          eps = data
              .whereType<Map>()
              .map((e) => PlayListItem.fromJson(Map<String, dynamic>.from(e)))
              .toList()
            ..sort((a, b) => _epNum(a).compareTo(_epNum(b)));
        }
      } catch (e) {
        debugPrint('SeriesScreen getEpisodeList error: $e');
      }
    }
    // 关键：切季时 _loading 由 _onSeasonTap 置 true，必须在此复位，
    // 否则 body 会一直停在 loading 分支（集已取到却不显示）。
    if (mounted) {
      setState(() {
        _episodes = eps;
        _loading = false;
      });
    }
  }

  Future<void> _loadViaApi() async {
    try {
      final sResp = await widget.api.getSeasonList(widget.tvGuid);
      final sData = sResp['data'];
      if (sData is List && sData.isNotEmpty) {
        final seasons = sData
            .whereType<Map>()
            .map((e) => PlayListItem.fromJson(Map<String, dynamic>.from(e)))
            .toList()
          ..sort((a, b) => _szNum(a).compareTo(_szNum(b)));
        _seasons = seasons;
        final initIdx = widget.initialSeasonGuid != null
            ? seasons.indexWhere((s) => s.guid == widget.initialSeasonGuid)
            : 0;
        _selectedSeason = initIdx < 0 ? 0 : initIdx;
        await _loadEpisodesForSeason(seasons[_selectedSeason], const <PlayListItem>[]);
        return;
      }
    } catch (e) {
      debugPrint('SeriesScreen getSeasonList error: $e');
    }
    // 没有季 → 尝试直接列集
    try {
      final eResp = await widget.api.getEpisodeList(widget.tvGuid);
      final eData = eResp['data'];
      if (eData is List) {
        final list = eData
            .whereType<Map>()
            .map((e) => PlayListItem.fromJson(Map<String, dynamic>.from(e)))
            .toList()
          ..sort((a, b) => _epNum(a).compareTo(_epNum(b)));
        _episodes = list;
        if (mounted) setState(() {});
        return;
      }
    } catch (e) {
      debugPrint('SeriesScreen getEpisodeList(tv) error: $e');
    }
    _episodes = [];
    if (mounted) setState(() {});
  }

  void _onSeasonTap(int index) {
    if (index == _selectedSeason) return;
    setState(() {
      _selectedSeason = index;
      _episodes = [];
      _loading = true;
    });
    _loadEpisodesForSeason(_seasons[index], widget.allItems ?? const <PlayListItem>[]);
  }

  void _onEpisodeTap(PlayListItem ep) {
    final seasonGuid = _seasons.isNotEmpty ? _seasons[_selectedSeason].guid : (ep.parentGuid ?? '');
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          itemGuid: ep.guid,
          title: ep.title ?? '',
          tvTitle: widget.tvTitle,
          episodeNumber: ep.episodeNumber,
          poster: ep.poster ?? '',
          category: 'TV',
          parentGuid: seasonGuid,
          logoUrl: widget.tvPoster,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalEps = _seasons.isNotEmpty
        ? _seasons.fold<int>(0, (s, sz) => s + (sz.localNumberOfEpisodes > 0 ? sz.localNumberOfEpisodes : 0))
        : _episodes.length;
    return Scaffold(
      backgroundColor: FnTheme.surfaceDark,
      appBar: AppBar(
        backgroundColor: FnTheme.surfaceDark,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.tvTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 14),
            child: Center(
              child: Text(
                _seasons.length > 1
                    ? '${_seasons.length} 季'
                    : (totalEps > 0 ? '$totalEps 集' : ''),
                style: const TextStyle(color: FnTheme.textSecondary, fontSize: 13)),
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: FnTheme.danmuGreen));
    }
    if (_loadError != null && _episodes.isEmpty && _seasons.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('加载失败：$_loadError',
            style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
        ),
      );
    }
    return Column(
      children: [
        if (_seasons.length > 1) _buildSeasonTabs(),
        Expanded(
          child: _episodes.isEmpty
              ? const Center(child: Text('暂无剧集', style: TextStyle(color: Colors.grey)))
              : _buildEpisodeList(),
        ),
      ],
    );
  }

  Widget _buildSeasonTabs() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        itemCount: _seasons.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final s = _seasons[i];
          final active = i == _selectedSeason;
          return ChoiceChip(
            label: Text(s.title ?? '第 ${s.seasonNumber} 季'),
            selected: active,
            selectedColor: FnTheme.danmuGreen,
            backgroundColor: FnTheme.cardBg,
            labelStyle: TextStyle(
              color: active ? Colors.black : FnTheme.textPrimary,
              fontSize: 13,
            ),
            onSelected: (_) => _onSeasonTap(i),
          );
        },
      ),
    );
  }

  Widget _buildEpisodeList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 20),
      itemCount: _episodes.length,
      separatorBuilder: (_, __) => const Divider(
        height: 1, color: Color(0xFF2A2A2A), indent: 14, endIndent: 14),
      itemBuilder: (_, i) => _episodeTile(_episodes[i]),
    );
  }

  Widget _episodeTile(PlayListItem ep) {
    final watched = ep.watched == 1 || ep.ts > 0;
    final hasProgress = ep.ts > 0;
    return InkWell(
      onTap: () => _onEpisodeTap(ep),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 集数（宽列，便于扫读）
            SizedBox(
              width: 42,
              child: Text(
                ep.episodeNumber > 0 ? '${ep.episodeNumber}' : '·',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                  color: FnTheme.danmuGreen,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 标题 + 续播进度
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ep.title ?? (ep.episodeNumber > 0 ? '第${ep.episodeNumber}集' : '未命名'),
                    style: const TextStyle(
                      fontSize: 14,
                      color: FnTheme.textPrimary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hasProgress)
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: LayoutBuilder(
                        builder: (ctx, c) => Container(
                          height: 3,
                          width: c.maxWidth,
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: _progressFactor(ep),
                            child: Container(
                              decoration: BoxDecoration(
                                color: FnTheme.danmuGreen,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (watched)
              const Icon(Icons.check_circle_rounded,
                color: FnTheme.danmuGreen, size: 18),
            const Icon(Icons.chevron_right_rounded,
              color: FnTheme.textMuted, size: 20),
          ],
        ),
      ),
    );
  }

  double _progressFactor(PlayListItem ep) {
    final dur = ep.duration > 0 ? ep.duration : 0;
    if (dur <= 0 || ep.ts <= 0) return 0.0;
    final f = ep.ts / dur;
    return f.clamp(0.03, 1.0);
  }
}
