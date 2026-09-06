import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'auth_utils.dart';
import '../models/play_list_item.dart';

class ApiClient {
  late Dio _dio;
  String? _token;
  String _baseUrl = '';
  Map<String, String>? _cachedImageHeaders;
  String? _cachedImageHeadersToken;

  ApiClient() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {'Content-Type': 'application/json'},
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final urlPath = options.uri.path;
        String? bodyStr;
        if (options.data != null) {
          bodyStr = options.data is String ? options.data as String : jsonEncode(options.data);
        }
        final authx = FnAuthUtils.genAuthx(urlPath, bodyStr);
        options.headers['Authx'] = authx;
        if (options.extra['noContentType'] == true) {
          options.headers.remove('Content-Type');
        } else {
          options.headers['Content-Type'] = 'application/json';
        }
        options.headers['Cookie'] = 'mode=relay';
        if (_token != null) {
          options.headers['Authorization'] = _token;
        }
        handler.next(options);
      },
    ));
  }

  String get baseUrl => _baseUrl;

  void updateBaseUrl(String host) {
    _baseUrl = host.replaceAll(RegExp(r'/+$'), '');
    final vIdx = _baseUrl.indexOf('/v');
    if (vIdx != -1) _baseUrl = _baseUrl.substring(0, vIdx);
    _dio.options.baseUrl = '$_baseUrl/v/';
  }

  void setToken(String token) {
    _token = token;
    _cachedImageHeaders = null;
    _cachedImageHeadersToken = null;
  }
  String? get token => _token;

  Dio get dio => _dio;

  // ====== API Methods ======

  Future<Map<String, dynamic>> login(String username, String password) async {
    final resp = await _dio.post('api/v1/login', data: {
      'app_name': 'trimemedia-web',
      'username': username,
      'password': password,
      'nonce': FnAuthUtils.generateNonce(),
    });
    return resp.data;
  }

  Future<Map<String, dynamic>> getUserInfo() async {
    final resp = await _dio.get('api/v1/user/info');
    return resp.data;
  }

  Future<Map<String, dynamic>> getMediaDbList() async {
    final resp = await _dio.get('api/v1/mediadb/list');
    return resp.data;
  }

  Future<Map<String, dynamic>> getItemList(Map<String, dynamic> body) async {
    final resp = await _dio.post('api/v1/item/list', data: body);
    return resp.data;
  }

  /// 按 guid 取单个条目的元信息（标题、类型、parent_guid 等）。
  /// 用于解析「虚拟文件夹」：FnOS 音乐库等场景下，目录节点不会出现在
  /// ancestor 平铺结果里，只能从子项的 parent_guid 得知其 guid，再用本接口取名字。
  Future<Map<String, dynamic>> getItemInfo(String guid) async {
    _apiDebug('getItemInfo guid=$guid');
    final resp = await _dio.get('api/v1/item/$guid');
    return resp.data;
  }

  // ====== 文件级调试日志（adb 联调用；发布稳定后默认关闭，需要时改回 true）======
  static const bool _kDebugApiLog = true;
  void _apiDebug(String msg) {
    if (!_kDebugApiLog) return;
    // release 构建也保证进 logcat（tag 通常为 flutter）
    print('FNTV_API $msg');
    // 文件日志 best-effort（debug 构建可读）
    try {
      const dir = '/sdcard/Android/data/com.fntv.byd/cache';
      Directory(dir).createSync(recursive: true);
      File('$dir/fntv_api.log').writeAsStringSync(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// 浏览媒体库/文件夹内的所有条目（自动翻页取满 total）。
  ///
  /// 严格对齐 Java 原项目 fnos_tv_danmu v1.2.9 的 browseItemsInContainer：
  /// - FnOS 嵌套文件夹 guid 以 `fv_` 开头，必须用 `parent_guid` 列出子项；
  ///   顶层媒体库源 guid 用 `ancestor_guid`。
  /// - 两类请求均使用 9 类 type 标签（BROWSE_TYPES），否则 Episode / Season / Collection
  ///   等子项会被过滤成空列表 → 界面「暂无内容」。此前移植把 ancestor 分支错写成 4 类型，
  ///   正是 L 林栋 等 Episode 子项文件夹恒空的根因。
  /// - 首轮空列表时回退尝试另一种 guid 形态，回退轮 exclude_grouped_video 统一为 0。
  static const List<String> _browseTypes = <String>[
    'Movie', 'TV', 'Directory', 'Video', 'Episode', 'Season', 'Collection', 'Folder', 'folder',
  ];

  /// 拉取某媒体库（顶层源）下的全部后代条目（自动翻页取满）。
  ///
  /// 用于「文件夹式层级浏览」：FnOS 对媒体库源只能用 ancestor_guid 列出其下所有
  /// 后代（parent_guid 对库 guid 恒返回空），且单个条目带 parent_guid 指向其父节点。
  /// 因此一次性拉全量，由 UI 按 parent_guid 分组，即可重建出多级目录树。
  /// exclude_grouped_video 统一为 0，避免漏掉被服务端 grouped 标记的视频。
  Future<List<PlayListItem>> fetchLibraryTree(String libGuid) async {
    _apiDebug('fetchLibraryTree libGuid=$libGuid');
    final items = await _fetchItemPageBatch(libGuid, false, excludeGrouped: false);
    _apiDebug('fetchLibraryTree 拉到 ${items.length} 条后代');
    return items;
  }

  /// 兼容旧调用：列出某容器（库源或 fv_ 目录）内容。
  /// 层级浏览请改用 [fetchLibraryTree] + 前端按 parent_guid 分组。
  Future<List<PlayListItem>> fetchItemsInContainer(String guid, {bool? forceParent}) async {
    final useParentFirst = forceParent ?? guid.startsWith('fv_');
    _apiDebug('fetchItemsInContainer guid=$guid useParentFirst=$useParentFirst');
    // 第一轮：fv_ → parent_guid(exclude=0)；非 fv_ → ancestor_guid(exclude=1)
    final first = await _fetchItemPageBatch(guid, useParentFirst, excludeGrouped: !useParentFirst);
    if (first.isNotEmpty) {
      _apiDebug('fetchItemsInContainer 第一轮命中 ${first.length} 项');
      return first;
    }
    // 回退：尝试另一种 guid 形态，exclude_grouped_video 统一为 0（对齐 Java 回退分支）
    _apiDebug('fetchItemsInContainer 第一轮空，回退另一种 guid 形态');
    final alt = await _fetchItemPageBatch(guid, !useParentFirst, excludeGrouped: false);
    _apiDebug('fetchItemsInContainer 回退结果 ${alt.length} 项');
    return alt;
  }

  /// 单页请求条数。
  ///
  /// FnOS 服务端对 item/list 的 page_size 存在上限（实测约 50），且部分版本
  /// 在响应里不返回可信的 total。旧实现只在 `all.length >= total` 时才停止翻页，
  /// 一旦 total 缺失 / 为 0 / 传回字符串，循环在第一页就退出，界面只能看到
  /// 服务端截断的那一页 —— 即「媒体库只能查看 50 个影视」。
  ///
  /// 修复要点：
  /// 1. 请求条数对齐服务端上限，避免「请求值 > 上限」时 offset 计算不一致；
  /// 2. 结束条件改为「取到空页才停」，total 只作为可选的提前结束依据；
  /// 3. 按 guid 去重，服务端未真正翻页（整页重复）时立即停止，不会死循环。
  static const int _browsePageSize = 50;
  /// 翻页硬上限，防止服务端异常时无限循环（50 × 400 = 20000 条）。
  static const int _maxBrowsePages = 400;

  Future<List<PlayListItem>> _fetchItemPageBatch(String guid, bool useParent,
      {required bool excludeGrouped}) async {
    final all = <PlayListItem>[];
    final seen = <String>{};
    int page = 1;
    while (page <= _maxBrowsePages) {
      final body = <String, dynamic>{
        'tags': {'type': _browseTypes},
        'exclude_grouped_video': excludeGrouped ? 1 : 0,
        'sort_type': useParent ? 'ASC' : 'DESC',
        'sort_column': useParent ? 'sort_title' : 'create_time',
        'page': page,
        'page_size': _browsePageSize,
      };
      if (useParent) {
        body['parent_guid'] = guid;
      } else {
        body['ancestor_guid'] = guid;
      }
      _apiDebug('REQ useParent=$useParent exclude=$excludeGrouped page=$page guid=$guid body=$body');
      final resp = await getItemList(body);
      _apiDebug('RESP code=${resp['code']} dataNull=${resp['data'] == null}');
      if (resp['code'] != 0 || resp['data'] == null || resp['data']['list'] == null) break;
      final rawList = resp['data']['list'];
      if (rawList is! List) break;
      final list = rawList.map((e) => PlayListItem.fromJson(e)).toList();

      // guid 去重：服务端翻页异常时可能重复返回同一批数据
      var added = 0;
      for (final it in list) {
        if (it.guid.isNotEmpty && !seen.add(it.guid)) continue;
        all.add(it);
        added++;
      }

      final types = list.take(8).map((e) => '${e.type}:${e.title}').join(', ');
      _apiDebug('RESP page=$page list=${list.length} added=$added '
          'total=${resp['data']['total']} sample=[$types]');
      final base = all.length - added;
      for (var i = 0; i < list.length; i++) {
        final it = list[i];
        if (it.isFolder) {
          _apiDebug('FOLDER page=$page idx=${base + i} guid=${it.guid} '
              'title=${it.title} type=${it.type}');
        }
      }

      final total = _readTotal(resp['data']);
      // 结束条件（按可靠性排序）：
      // 1) 空页：确实取完了（total 不可信时靠它兜底，正是修复 50 条上限的关键）
      // 2) 整页重复：服务端没有真正翻页，继续请求只会拿到同样的数据
      // 3) total 可信且已取满
      if (list.isEmpty) break;
      if (added == 0) break;
      if (total > 0 && all.length >= total) break;
      page++;
    }
    _apiDebug('fetchItemPageBatch done guid=$guid useParent=$useParent '
        'pages=$page items=${all.length}');
    return all;
  }

  /// 安全读取服务端 total：可能是 int / String / null，
  /// 取不到时返回 -1（表示不可信，改由「空页」判定结束）。
  static int _readTotal(dynamic data) {
    final t = data is Map ? data['total'] : null;
    if (t is int) return t;
    if (t is num) return t.toInt();
    if (t is String) return int.tryParse(t) ?? -1;
    return -1;
  }

  Future<Map<String, dynamic>> getEpisodeList(String id) async {
    final resp = await _dio.get('api/v1/episode/list/$id');
    return resp.data;
  }

  Future<Map<String, dynamic>> getSeasonList(String parentGuid) async {
    final resp = await _dio.get('api/v1/season/list/$parentGuid');
    return resp.data;
  }

  Future<Map<String, dynamic>> getGenres({String lan = 'zh-CN'}) async {
    final resp = await _dio.get('api/v1/tag/genres', queryParameters: {'lan': lan});
    return resp.data;
  }

  Future<Map<String, dynamic>> getPlayInfo(String itemGuid) async {
    final resp = await _dio.post('api/v1/play/info', data: {'item_guid': itemGuid});
    return resp.data;
  }

  Future<Map<String, dynamic>> getItemDetail(String guid) async {
    final resp = await _dio.get('api/v1/item/$guid');
    return resp.data;
  }

  Future<Map<String, dynamic>> getPersonList(String itemGuid, {int page = 1, int pageSize = 200}) async {
    final resp = await _dio.post('api/v1/person/list/$itemGuid', data: {'page': page, 'page_size': pageSize});
    return resp.data;
  }

  Future<Map<String, dynamic>> getStream(Map<String, dynamic> body) async {
    final resp = await _dio.post('api/v1/stream', data: body);
    return resp.data;
  }

  Future<Map<String, dynamic>> getStreamList(String mediaGuid) async {
    final resp = await _dio.get('api/v1/stream/list/$mediaGuid');
    return resp.data;
  }

  String getMediaUrl(String mediaGuid) {
    return '$_baseUrl/v/api/v1/media/range/$mediaGuid';
  }

  String getMediaUrlWithQuality(String mediaGuid, int qualityIndex) {
    return '$_baseUrl/v/api/v1/media/range/$mediaGuid?direct_link_quality_index=$qualityIndex';
  }

  String getMediaUrlWithTranscodeQuality(String mediaGuid, int qualityIndex) {
    return '$_baseUrl/v/api/v1/media/range/$mediaGuid?quality_index=$qualityIndex';
  }

  String getImageUrl(String? path, {int width = 400}) {
    if (path == null || path.isEmpty) return '';
    final p = path.startsWith('/') ? path : '/$path';
    return '$_baseUrl/v/api/v1/sys/img$p?w=$width';
  }

  /// 返回视频/图片请求所需的通用认证头
  Map<String, String> get headers {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Cookie': 'mode=relay',
    };
    if (_token != null) {
      h['Authorization'] = _token!;
    }
    return h;
  }

  /// 播放器（media_kit / ExoPlayer）直接拉流时所需的请求头。
  ///
  /// 关键修复：Dio 拦截器会自动给所有【API 请求】加 Authx 签名，但播放器是
  /// 独立 HTTP 拉流（不经过 Dio），必须在此显式带上 Authx，否则 fnOS 的
  /// /v/api/v1/media/range 端点返回 403 → 表现为「黑屏 + 控制栏读不到时长」
  /// （两个内核都会失败，因为问题在流地址鉴权而非解码）。
  /// 头字段与 Java 端 AuthInterceptor 对齐：Authx / Cookie / x-trim-client /
  /// x-trim-client-version / Authorization。
  Map<String, String> mediaHeaders(String url) {
    final h = <String, String>{
      'Content-Type': 'application/json',
      'Cookie': 'mode=relay',
      'x-trim-client': 'web',
      'x-trim-client-version': '608',
    };
    if (_token != null) {
      h['Authorization'] = _token!;
    }
    try {
      final uri = Uri.parse(url);
      final path = uri.path.isNotEmpty ? uri.path : '/';
      final baseHost = Uri.tryParse(_baseUrl)?.host ?? '';
      // 仅对 fnOS 同域（或无法判定 host）的地址加 Authx；外部直链一般忽略该头。
      // Authx 以 path 签名（不含 query），与 Java AuthInterceptor.genAuthx(path, null) 一致。
      if (baseHost.isEmpty || uri.host.isEmpty || uri.host == baseHost) {
        h['Authx'] = FnAuthUtils.genAuthx(path, null);
      }
    } catch (_) {
      // URL 解析失败时不附加 Authx，避免崩溃（拉流会按服务端响应走正常失败路径）。
    }
    return h;
  }

  /// 返回图片请求所需的认证头，供 CachedNetworkImage 使用
  Map<String, String> get imageHeaders {
    if (_cachedImageHeaders != null && _cachedImageHeadersToken == _token) {
      return _cachedImageHeaders!;
    }
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Cookie': 'mode=relay',
    };
    if (_token != null) {
      headers['Authorization'] = _token!;
    }
    final authx = FnAuthUtils.genAuthx('/v/api/v1/sys/img', null);
    headers['Authx'] = authx;
    _cachedImageHeaders = headers;
    _cachedImageHeadersToken = _token;
    return headers;
  }

  Future<void> recordPlayStatus(Map<String, dynamic> body) async {
    await _dio.post('api/v1/play/record', data: body);
  }

  /// 获取继续观看列表（服务端播放记录）
  Future<Map<String, dynamic>> getPlayList() async {
    final resp = await _dio.get('api/v1/play/list');
    return resp.data;
  }

  Future<void> setWatched(Map<String, dynamic> body) async {
    await _dio.post('api/v1/item/watched', data: body);
  }
}
