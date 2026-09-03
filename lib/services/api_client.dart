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

  // ====== 文件级调试日志（adb 联调用；发布稳定后默认关闭，需要时改回 true）======
  static const bool _kDebugApiLog = false;
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

  Future<List<PlayListItem>> _fetchItemPageBatch(String guid, bool useParent,
      {required bool excludeGrouped}) async {
    final all = <PlayListItem>[];
    int page = 1;
    const pageSize = 200;
    while (true) {
      final body = <String, dynamic>{
        'tags': {'type': _browseTypes},
        'exclude_grouped_video': excludeGrouped ? 1 : 0,
        'sort_type': useParent ? 'ASC' : 'DESC',
        'sort_column': useParent ? 'sort_title' : 'create_time',
        'page': page,
        'page_size': pageSize,
      };
      if (useParent) {
        body['parent_guid'] = guid;
      } else {
        body['ancestor_guid'] = guid;
      }
      _apiDebug('REQ useParent=$useParent exclude=$excludeGrouped guid=$guid body=$body');
      final resp = await getItemList(body);
      _apiDebug('RESP code=${resp['code']} dataNull=${resp['data'] == null}');
      if (resp['code'] != 0 || resp['data'] == null || resp['data']['list'] == null) break;
      final list = (resp['data']['list'] as List)
          .map((e) => PlayListItem.fromJson(e))
          .toList();
      final types = list.take(8).map((e) => '${e.type}:${e.title}').join(', ');
      _apiDebug('RESP list=${list.length} total=${resp['data']['total']} sample=[$types]');
      all.addAll(list);
      final total = (resp['data']['total'] ?? 0).toInt();
      if (list.isEmpty || all.length >= total) break;
      page++;
    }
    return all;
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
