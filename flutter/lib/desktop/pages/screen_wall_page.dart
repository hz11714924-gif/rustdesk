import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/screen_wall_model.dart';

const screenWallTabKey = 'screen-wall';

class ScreenWallPage extends StatefulWidget {
  const ScreenWallPage({Key? key}) : super(key: key);

  static bool _uploadsResumed = false;

  static Future<void> resumeUploads() async {
    if (!isWindows || _uploadsResumed) return;
    _uploadsResumed = true;
    try {
      final raw = bind.mainGetLocalOption(key: screenWallConfigKey);
      if (ScreenWallConfig.decode(raw).uploadEnabled) {
        await bind.mainSetLocalOption(key: screenWallConfigKey, value: raw);
      }
    } catch (_) {
      debugPrint('Screen wall upload settings could not be resumed');
    }
  }

  @override
  State<ScreenWallPage> createState() => _ScreenWallPageState();
}

class _ScreenWallPageState extends State<ScreenWallPage>
    with AutomaticKeepAliveClientMixin {
  ScreenWallConfig _config = const ScreenWallConfig();
  ScreenWallClient? _client;
  Timer? _timer;
  List<ScreenWallDevice> _devices = [];
  Map<String, ScreenWallImage> _images = {};
  Set<String> _imageFailures = {};
  Map<String, dynamic> _uploadStatus = {};
  String? _error;
  String _search = '';
  bool _refreshing = false;
  int _generation = 0;
  int _serverOffsetSeconds = 0;
  DateTime? _lastRefreshed;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    try {
      _config = ScreenWallConfig.decode(
          bind.mainGetLocalOption(key: screenWallConfigKey));
      if (_config.canView) _client = ScreenWallClient(_config);
    } catch (_) {
      _error = '屏幕墙设置无效，请重新保存设置';
    }
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  void _readUploadStatus() {
    try {
      final raw = bind.mainGetLocalOption(key: screenWallStatusKey);
      final value = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
      _uploadStatus = value is Map<String, dynamic> ? value : {};
    } catch (_) {
      _uploadStatus = {'last_error': '暂时无法读取本机上报状态'};
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    _readUploadStatus();
    final client = _client;
    if (client == null || _refreshing) {
      setState(() {});
      return;
    }
    final generation = _generation;
    setState(() => _refreshing = true);
    try {
      final snapshot = await client.loadDevices();
      final images = await client.loadImages(snapshot.devices, _images);
      if (!mounted || generation != _generation) return;
      setState(() {
        _devices = snapshot.devices;
        _images = images.images;
        _imageFailures = images.failures;
        _serverOffsetSeconds = snapshot.serverTime -
            DateTime.now().millisecondsSinceEpoch ~/ 1000;
        _lastRefreshed = DateTime.now();
        _error = null;
      });
    } on ScreenWallApiException catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error.message);
      }
    } on TimeoutException {
      if (mounted && generation == _generation) {
        setState(() => _error = '连接预览服务超时，请稍后刷新');
      }
    } on FormatException {
      if (mounted && generation == _generation) {
        setState(() => _error = '预览服务返回的数据格式不正确');
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = '无法连接预览服务，请检查网络和 HTTPS 证书');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _refreshing = false);
      }
    }
  }

  void _applyConfig(ScreenWallConfig config) {
    _generation++;
    _client?.close();
    setState(() {
      _config = config;
      _client = config.canView ? ScreenWallClient(config) : null;
      _devices = [];
      _images = {};
      _imageFailures = {};
      _error = null;
      _refreshing = false;
      _lastRefreshed = null;
    });
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client?.close();
    super.dispose();
  }

  Future<void> _showSettings() async {
    if (bind.isDisableSettings()) return;
    final api = TextEditingController(text: _config.apiUrl);
    final ca = TextEditingController(text: _config.caPem);
    final viewer = TextEditingController(text: _config.viewerToken);
    final upload = TextEditingController(text: _config.uploadToken);
    final name = TextEditingController(text: _config.deviceName);
    final interval =
        TextEditingController(text: _config.intervalSeconds.toString());
    final form = GlobalKey<FormState>();
    var uploadEnabled = _config.uploadEnabled;
    var saving = false;
    String? saveError;
    ScreenWallConfig? saved;
    try {
      saved = await showDialog<ScreenWallConfig>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, updateDialog) => AlertDialog(
            title: const Text('屏幕墙设置'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Form(
                  key: form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('预览服务'),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: api,
                        enabled: !saving,
                        decoration: const InputDecoration(
                          labelText: '服务地址（HTTPS）',
                          hintText: 'https://preview.example.com',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if ((value ?? '').trim().isEmpty &&
                              !uploadEnabled &&
                              viewer.text.trim().isEmpty) return null;
                          try {
                            ScreenWallConfig(apiUrl: value!.trim()).apiUri;
                            return null;
                          } on FormatException catch (error) {
                            return error.message;
                          }
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: ca,
                        enabled: !saving,
                        minLines: 3,
                        maxLines: 5,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: '自签 CA 证书（PEM，可选）',
                          helperText: '留空使用系统信任；自签服务填写 CA 公钥证书，仍校验服务地址',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            utf8.encode(value ?? '').length > 16 * 1024
                                ? 'CA 证书不能超过 16 KiB'
                                : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: viewer,
                        enabled: !saving,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: '查看令牌',
                          helperText: '仅上报本机时可留空',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const Divider(height: 32),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: uploadEnabled,
                        onChanged: saving
                            ? null
                            : (value) =>
                                updateDialog(() => uploadEnabled = value),
                        title: const Text('上报本机屏幕预览'),
                        subtitle: const Text(
                            '开启后，本应用运行期间会定时截取本机屏幕缩略图并上传到此服务。可随时关闭。'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: upload,
                        enabled: !saving,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: '上传令牌',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => uploadEnabled &&
                                (value ?? '').trim().isEmpty
                            ? '开启本机上报需要填写上传令牌'
                            : null,
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: name,
                        enabled: !saving,
                        maxLength: 80,
                        decoration: const InputDecoration(
                          labelText: '本机显示名称',
                          helperText: '留空使用本机默认名称',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: interval,
                        enabled: !saving,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: const InputDecoration(
                          labelText: '采集间隔（秒）',
                          helperText: '30 到 86400 秒，默认 300 秒',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final seconds = int.tryParse(value ?? '');
                          return seconds == null ||
                                  seconds < 30 ||
                                  seconds > 86400
                              ? '请输入 30 到 86400 之间的秒数'
                              : null;
                        },
                      ),
                      const SizedBox(height: 12),
                      const Text('预览采集不建立远控会话；点击设备卡片后使用 RustDesk 正常远控。'),
                      if (saveError != null) ...[
                        const SizedBox(height: 12),
                        Text(saveError!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed:
                    saving ? null : () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        if (!form.currentState!.validate()) return;
                        final config = ScreenWallConfig(
                          apiUrl: api.text.trim(),
                          caPem: ca.text.trim(),
                          viewerToken: viewer.text.trim(),
                          uploadEnabled: uploadEnabled,
                          uploadToken: upload.text.trim(),
                          deviceName: name.text.trim(),
                          intervalSeconds: int.parse(interval.text),
                        );
                        try {
                          config.validate();
                          updateDialog(() {
                            saving = true;
                            saveError = null;
                          });
                          await bind.mainSetLocalOption(
                              key: screenWallConfigKey,
                              value: jsonEncode(config.toJson()));
                          final status = jsonDecode(bind.mainGetLocalOption(
                              key: screenWallStatusKey));
                          final settingsError = status is Map<String, dynamic>
                              ? status['settings_error']
                              : null;
                          if (settingsError is String &&
                              settingsError.isNotEmpty) {
                            throw FormatException('设置未保存：$settingsError');
                          }
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop(config);
                          }
                        } on FormatException catch (error) {
                          if (dialogContext.mounted) {
                            updateDialog(() {
                              saving = false;
                              saveError = error.message;
                            });
                          }
                        } catch (_) {
                          if (dialogContext.mounted) {
                            updateDialog(() {
                              saving = false;
                              saveError = '保存设置失败，请稍后重试';
                            });
                          }
                        }
                      },
                child: Text(saving ? '保存中…' : '保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      for (final controller in [api, ca, viewer, upload, name, interval]) {
        controller.dispose();
      }
    }
    if (saved != null && mounted) _applyConfig(saved);
  }

  String _formatTime(dynamic value) {
    final seconds = value is int ? value : int.tryParse('$value');
    if (seconds == null || seconds <= 0) return '尚未上报';
    try {
      final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
      String two(int part) => part.toString().padLeft(2, '0');
      return '${time.year}-${two(time.month)}-${two(time.day)} '
          '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    } catch (_) {
      return '未知时间';
    }
  }

  Widget _buildUploadStatus() {
    final settingsError = _uploadStatus['settings_error'];
    final error = settingsError is String && settingsError.isNotEmpty
        ? settingsError
        : _uploadStatus['last_error'];
    final state = _uploadStatus['state'];
    final enabled = _uploadStatus['enabled'] == true;
    final deviceId = _uploadStatus['device_id'];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 18,
            runSpacing: 5,
            children: [
              Text(_config.uploadEnabled
                  ? (enabled ? '本机预览上报已开启' : '本机预览上报等待启动')
                  : '本机预览上报已关闭'),
              if (deviceId is String && deviceId.isNotEmpty)
                Text('本机 ID：$deviceId'),
              if (_config.uploadEnabled)
                Text('最近成功：${_formatTime(_uploadStatus['last_success_at'])}'),
              if (_config.uploadEnabled && state == 'uploading')
                const Text('正在上传…'),
            ],
          ),
          if (error is String && error.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _buildCard(ScreenWallDevice device) {
    final image = _images[device.id];
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000 +
        _serverOffsetSeconds;
    final stale = device.isStale(now, imageUpdatedAt: image?.updatedAt);
    final failed = _imageFailures.contains(device.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: bind.isIncomingOnly() ? null : () => connect(context, device.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Colors.black,
                child: image == null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.image_not_supported_outlined,
                                color: Colors.white54, size: 32),
                            const SizedBox(height: 8),
                            Text(failed ? '预览加载失败' : '暂无预览图片',
                                style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      )
                    : Image.memory(
                        image.bytes,
                        fit: BoxFit.contain,
                        cacheWidth: 640,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Text('无法显示预览图片',
                              style: TextStyle(color: Colors.white70)),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: device.name,
                          child: Text(device.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      if (stale)
                        Text('预览陈旧',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('ID：${device.id}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text('采集：${_formatTime(image?.updatedAt ?? device.updatedAt)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                  if (failed && image != null)
                    Text('更新失败，显示上次预览',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final configured = _client != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.grid_view_outlined,
                size: 48, color: Theme.of(context).disabledColor),
            const SizedBox(height: 16),
            Text(!configured
                ? '先配置屏幕墙服务'
                : (_error != null ? '预览暂不可用' : '暂无上报设备')),
            const SizedBox(height: 8),
            Text(
              !configured
                  ? '填写 HTTPS 服务地址和查看令牌后，设备预览会显示在这里。'
                  : '在需要查看的设备上开启“上报本机屏幕预览”，等待首次上报。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!configured && !bind.isDisableSettings()) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _showSettings, child: const Text('打开设置')),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final visible = _devices.where((device) =>
        _search.isEmpty ||
        device.name.toLowerCase().contains(_search) ||
        device.id.toLowerCase().contains(_search)).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(Icons.grid_view_outlined),
                  const SizedBox(width: 10),
                  Text('屏幕墙', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(width: 12),
                  Text('${_devices.length} 台设备',
                      style: Theme.of(context).textTheme.bodySmall),
                  const Spacer(),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _refreshing || _client == null ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                  const SizedBox(width: 6),
                  if (!bind.isDisableSettings())
                    OutlinedButton.icon(
                      onPressed: _showSettings,
                      icon: const Icon(Icons.settings_outlined, size: 18),
                      label: const Text('设置'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                onChanged: (value) =>
                    setState(() => _search = value.trim().toLowerCase()),
                decoration: const InputDecoration(
                  hintText: '搜索设备名称或 ID',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '每 30 秒检查更新，仅下载变化的预览'
                  '${_lastRefreshed == null ? '' : ' · 更新于 ${_formatTime(_lastRefreshed!.millisecondsSinceEpoch ~/ 1000)}'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        _buildUploadStatus(),
        if (_refreshing) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Theme.of(context).colorScheme.error.withOpacity(0.08),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        Expanded(
          child: _devices.isEmpty
              ? (_refreshing ? const Center(child: CircularProgressIndicator()) : _buildEmpty())
              : (visible.isEmpty
                  ? const Center(child: Text('没有匹配的设备'))
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 360,
                        childAspectRatio: 1.2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                      ),
                      itemCount: visible.length,
                      itemBuilder: (_, index) => _buildCard(visible[index]),
                    )),
        ),
      ],
    );
  }
}
