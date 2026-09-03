import 'dart:convert';
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

  /// 浏览媒体库/文件夹内的所有条目（自动翻页取满 total）。
  ///
  /// FnOS 嵌套文件夹 guid 以 `fv_` 开头，必须用 `parent_guid` 才能列出子项；
  /// 顶层媒体库源 guid 用 `ancestor_guid`。两者任一返回空列表时，自动回退尝试
  /// 另一种 guid 形态（参照 Java 原项目 fnos_tv_danmu v1.2.9 修复「暂无内容」）。
  Future<List<PlayListItem>> fetchItemsInContainer(String guid, {bool? forceParent}) async {
    final useParentFirst = forceParent ?? guid.startsWith('fv_');
    final first = await _fetchItemPageBatch(guid, useParentFirst);
    if (first.isNotEmpty) return first;
    // 首轮空列表：回退尝试另一种 guid 形态（fv_ 文件夹试 ancestor_guid，媒体库源试 parent_guid）
    final alt = await _fetchItemPageBatch(guid, !useParentFirst);
    return alt;
  }

  Future<List<PlayListItem>> _fetchItemPageBatch(String guid, bool useParent) async {
    final all = <PlayListItem>[];
    int page = 1;
    const pageSize = 200;
    while (true) {
      final body = <String, dynamic>{
        'tags': {
          'type': useParent
              ? ['Movie', 'TV', 'Directory', 'Video', 'Episode', 'Season', 'Collection', 'Folder', 'folder']
              : ['Movie', 'TV', 'Directory', 'Video'],
        },
        'exclude_grouped_video': useParent ? 0 : 1,
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
      final resp = await getItemList(body);
      if (resp['code'] != 0 || resp['data'] == null || resp['data']['list'] == null) break;
      final list = (resp['data']['list'] as List)
          .map((e) => PlayListItem.fromJson(e))
          .toList();
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
