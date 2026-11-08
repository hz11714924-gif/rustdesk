import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const screenWallConfigKey = 'screen-wall-config';
const screenWallStatusKey = 'screen-wall-status';
const screenWallMaximumImageBytes = 256 * 1024;

class ScreenWallConfig {
  final String apiUrl;
  final String viewerToken;
  final bool uploadEnabled;
  final String uploadToken;
  final String deviceName;
  final int intervalSeconds;

  const ScreenWallConfig({
    this.apiUrl = '',
    this.viewerToken = '',
    this.uploadEnabled = false,
    this.uploadToken = '',
    this.deviceName = '',
    this.intervalSeconds = 300,
  });

  factory ScreenWallConfig.decode(String value) {
    if (value.isEmpty) return const ScreenWallConfig();
    final data = jsonDecode(value);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Invalid screen wall settings');
    }
    final interval = data['interval_seconds'];
    return ScreenWallConfig(
      apiUrl: data['api_url'] is String ? data['api_url'] : '',
      viewerToken: data['viewer_token'] is String ? data['viewer_token'] : '',
      uploadEnabled: data['upload_enabled'] == true,
      uploadToken: data['upload_token'] is String ? data['upload_token'] : '',
      deviceName: data['device_name'] is String ? data['device_name'] : '',
      intervalSeconds: interval is int ? interval : 300,
    );
  }

  Map<String, dynamic> toJson() => {
        'api_url': apiUrl,
        'viewer_token': viewerToken,
        'upload_enabled': uploadEnabled,
        'upload_token': uploadToken,
        'device_name': deviceName,
        'interval_seconds': intervalSeconds,
      };

  Uri get apiUri {
    final uri = Uri.tryParse(apiUrl.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('服务地址必须使用 HTTPS，且不能包含账号、查询参数或片段');
    }
    return uri;
  }

  void validate() {
    if (apiUrl.isNotEmpty || uploadEnabled || viewerToken.isNotEmpty) {
      apiUri;
    }
    if (uploadEnabled && uploadToken.trim().isEmpty) {
      throw const FormatException('开启本机上报需要填写上传令牌');
    }
    if (intervalSeconds < 30 || intervalSeconds > 86400) {
      throw const FormatException('采集间隔必须在 30 到 86400 秒之间');
    }
    if (deviceName.length > 80) {
      throw const FormatException('设备名称最多 80 个字符');
    }
    if (viewerToken.contains(RegExp(r'[\r\n]')) ||
        uploadToken.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('令牌不能包含换行');
    }
  }

  bool get canView => apiUrl.trim().isNotEmpty && viewerToken.trim().isNotEmpty;
}

class ScreenWallDevice {
  final String id;
  final String name;
  final int updatedAt;
  final int width;
  final int height;
  final int intervalSeconds;
  final String imagePath;

  const ScreenWallDevice({
    required this.id,
    required this.name,
    required this.updatedAt,
    required this.width,
    required this.height,
    required this.intervalSeconds,
    required this.imagePath,
  });

  factory ScreenWallDevice.fromJson(Map<String, dynamic> data) {
    final id = data['id'];
    final updated = data['updated_at'];
    final width = data['width'];
    final height = data['height'];
    final path = data['image_path'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        id == '.' ||
        id == '..' ||
        updated is! int ||
        updated < 0 ||
        width is! int ||
        width <= 0 ||
        height is! int ||
        height <= 0 ||
        path != '/api/previews/${Uri.encodeComponent(id)}/image') {
      throw const FormatException('Invalid screen wall device');
    }
    final interval = data['interval_seconds'];
    return ScreenWallDevice(
      id: id,
      name: data['name'] is String && (data['name'] as String).trim().isNotEmpty
          ? data['name']
          : id,
      updatedAt: updated,
      width: width,
      height: height,
      intervalSeconds: interval is int && interval >= 30 && interval <= 86400
          ? interval
          : 300,
      imagePath: path,
    );
  }

  bool isStale(int now, {int? imageUpdatedAt}) {
    final age = now - (imageUpdatedAt ?? updatedAt);
    final threshold = intervalSeconds * 2.5;
    return age > (threshold > 600 ? threshold : 600);
  }
}

class ScreenWallSnapshot {
  final List<ScreenWallDevice> devices;
  final int serverTime;

  const ScreenWallSnapshot(this.devices, this.serverTime);

  factory ScreenWallSnapshot.fromJson(dynamic data) {
    if (data is! Map<String, dynamic> ||
        data['devices'] is! List ||
        data['server_time'] is! int) {
      throw const FormatException('Invalid screen wall response');
    }
    final devices = <ScreenWallDevice>[];
    final ids = <String>{};
    for (final value in data['devices']) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Invalid screen wall device');
      }
      final device = ScreenWallDevice.fromJson(value);
      if (!ids.add(device.id)) {
        throw const FormatException('Duplicate screen wall device');
      }
      devices.add(device);
    }
    return ScreenWallSnapshot(devices, data['server_time']);
  }
}

class ScreenWallImage {
  final int updatedAt;
  final Uint8List bytes;

  const ScreenWallImage(this.updatedAt, this.bytes);
}

class ScreenWallImages {
  final Map<String, ScreenWallImage> images;
  final Set<String> failures;

  const ScreenWallImages(this.images, this.failures);
}

class ScreenWallApiException implements Exception {
  final String message;

  const ScreenWallApiException(this.message);
}

class ScreenWallClient {
  final ScreenWallConfig config;
  final http.Client _client;
  final Uri _base;
  static const _timeout = Duration(seconds: 20);

  ScreenWallClient(this.config, {http.Client? client})
      : _client = client ?? http.Client(),
        _base = config.apiUri {
    config.validate();
  }

  Future<Uint8List> _get(Uri uri, int maximumBytes, String accept) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${config.viewerToken}',
        'Accept': accept,
      });
    final watch = Stopwatch()..start();
    final response = await _client.send(request).timeout(_timeout);
    if (response.statusCode != 200 ||
        (response.contentLength != null && response.contentLength! > maximumBytes)) {
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw const ScreenWallApiException('查看令牌无效或没有权限');
      }
      if (response.statusCode != 200) {
        throw ScreenWallApiException('预览服务返回 HTTP ${response.statusCode}');
      }
      throw const ScreenWallApiException('预览服务返回的内容过大');
    }
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator(response.stream);
    try {
      while (true) {
        final remaining = _timeout - watch.elapsed;
        if (remaining <= Duration.zero ||
            !await iterator.moveNext().timeout(remaining)) {
          if (remaining <= Duration.zero) throw TimeoutException('Preview timeout');
          break;
        }
        if (bytes.length + iterator.current.length > maximumBytes) {
          throw const ScreenWallApiException('预览服务返回的内容过大');
        }
        bytes.add(iterator.current);
      }
    } finally {
      await iterator.cancel();
    }
    return bytes.takeBytes();
  }

  Future<ScreenWallSnapshot> loadDevices() async {
    final bytes = await _get(_endpoint('/api/previews'), 4 * 1024 * 1024,
        'application/json');
    return ScreenWallSnapshot.fromJson(jsonDecode(utf8.decode(bytes)));
  }

  Future<ScreenWallImage> _loadImage(ScreenWallDevice device) async {
    if (device.imagePath != '/api/previews/${Uri.encodeComponent(device.id)}/image') {
      throw const ScreenWallApiException('预览图片地址无效');
    }
    final bytes = await _get(_endpoint(device.imagePath),
        screenWallMaximumImageBytes, 'image/jpeg');
    if (bytes.length < 4 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8 ||
        bytes[bytes.length - 2] != 0xff ||
        bytes.last != 0xd9) {
      throw const ScreenWallApiException('预览图片格式无效');
    }
    return ScreenWallImage(device.updatedAt, bytes);
  }

  Uri _endpoint(String path) {
    final base = _base.replace(
        path: '${_base.path.replaceAll(RegExp(r'/+$'), '')}/');
    return base.resolve(path.substring(1));
  }

  Future<ScreenWallImages> loadImages(List<ScreenWallDevice> devices,
      Map<String, ScreenWallImage> previous) async {
    final images = <String, ScreenWallImage>{};
    final failures = <String>{};
    var next = 0;
    Future<void> worker() async {
      while (next < devices.length) {
        final device = devices[next++];
        final old = previous[device.id];
        if (old != null) images[device.id] = old;
        if (old?.updatedAt == device.updatedAt) continue;
        try {
          images[device.id] = await _loadImage(device);
        } catch (_) {
          failures.add(device.id);
        }
      }
    }

    await Future.wait(List.generate(devices.length < 4 ? devices.length : 4,
        (_) => worker()));
    return ScreenWallImages(images, failures);
  }

  void close() => _client.close();
}
