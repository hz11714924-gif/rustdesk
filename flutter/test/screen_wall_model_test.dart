import 'dart:convert';

import 'package:flutter_hbb/models/screen_wall_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> deviceJson({int updatedAt = 1000}) => {
      'id': '123456789',
      'name': 'Office PC',
      'updated_at': updatedAt,
      'width': 320,
      'height': 180,
      'interval_seconds': 300,
      'image_path': '/api/previews/123456789/image',
    };

void main() {
  test('upload starts disabled and settings require HTTPS and a valid interval',
      () {
    final defaults = ScreenWallConfig.decode('');
    expect(defaults.uploadEnabled, isFalse);
    expect(defaults.intervalSeconds, 300);
    expect(defaults.canView, isFalse);
    expect(defaults.caPem, isEmpty);
    const ca = '-----BEGIN CERTIFICATE-----\nexample\n-----END CERTIFICATE-----';
    final restored = ScreenWallConfig.decode(jsonEncode(
        const ScreenWallConfig(caPem: ca).toJson()));
    expect(restored.caPem, ca);
    expect(
        () => ScreenWallConfig(caPem: ''.padLeft(16 * 1024 + 1, 'x')).validate(),
        throwsFormatException);
    expect(
        () => const ScreenWallConfig(apiUrl: 'http://preview.example.com')
            .validate(),
        throwsFormatException);
    expect(() => const ScreenWallConfig(intervalSeconds: 0).validate(),
        throwsFormatException);
    expect(() => const ScreenWallConfig(intervalSeconds: 1).validate(),
        returnsNormally);
    final managed = ScreenWallConfig.decode(jsonEncode(const ScreenWallConfig(
      apiUrl: 'https://preview.example.com',
      viewerToken: 'private-viewer',
      uploadToken: 'private-uploader',
      uploadEnabled: false,
      credentialsManaged: true,
    ).toJson()));
    expect(managed.credentialsManaged, isTrue);
    expect(managed.uploadEnabled, isFalse);
    expect(managed.viewerToken, 'private-viewer');
    expect(managed.uploadToken, 'private-uploader');
    expect(
        () => const ScreenWallConfig(
                apiUrl: 'https://preview.example.com', uploadEnabled: true)
            .validate(),
        throwsFormatException);
    final device = ScreenWallDevice.fromJson(deviceJson());
    expect(device.isStale(1750), isFalse);
    expect(device.isStale(1751), isTrue);
  });

  test('polling stays at thirty seconds for empty and slow device lists', () {
    expect(screenWallPollIntervalSeconds([]), 30);
    expect(screenWallPollIntervalSeconds([
      ScreenWallDevice.fromJson(deviceJson()),
    ]), 30);
  });

  test('polling follows the shortest one-second-capable device interval', () {
    final fast = deviceJson()..['interval_seconds'] = 1;
    final medium = deviceJson()..['interval_seconds'] = 5;
    final fastDevice = ScreenWallDevice.fromJson(fast);
    expect(fastDevice.intervalSeconds, 1);
    expect(screenWallPollIntervalSeconds([
      ScreenWallDevice.fromJson(deviceJson()),
      ScreenWallDevice.fromJson(medium),
    ]), 5);
    expect(screenWallPollIntervalSeconds([
      ScreenWallDevice.fromJson(medium), fastDevice,
    ]), 1);
  });

  test('polling reuses unchanged images and keeps list and image API base paths',
      () async {
    final imageRequests = <Uri>[];
    final client = ScreenWallClient(
      const ScreenWallConfig(
        apiUrl: 'https://preview.example.com/wall/',
        viewerToken: 'viewer-secret',
        uploadToken: 'upload-secret',
        caPem: '-----BEGIN CERTIFICATE-----\nexample\n-----END CERTIFICATE-----',
      ),
      client: MockClient((request) async {
        final headers = {
          for (final entry in request.headers.entries)
            entry.key.toLowerCase(): entry.value
        };
        expect(headers['authorization'], 'Bearer viewer-secret');
        expect(request.headers.values, isNot(contains('upload-secret')));
        expect(request.followRedirects, isFalse);
        if (request.url.path == '/wall/api/previews') {
          return http.Response(
              jsonEncode({
                'devices': [deviceJson()],
                'server_time': 1050,
              }),
              200);
        }
        expect(request.url.path, '/wall/api/previews/123456789/image');
        imageRequests.add(request.url);
        return http.Response.bytes([0xff, 0xd8, 0xff, 0xd9], 200);
      }),
    );
    addTearDown(client.close);
    final snapshot = await client.loadDevices();
    final first = await client.loadImages(snapshot.devices, {});
    expect(first.failures, isEmpty);
    expect(first.images['123456789']!.updatedAt, 1000);
    final unchanged = await client.loadImages(snapshot.devices, first.images);
    expect(unchanged.images['123456789'], same(first.images['123456789']));
    expect(imageRequests, hasLength(1));
    final changed = ScreenWallDevice.fromJson(deviceJson(updatedAt: 1100));
    final latest = await client.loadImages([changed], unchanged.images);
    expect(latest.images['123456789']!.updatedAt, 1100);
    expect(imageRequests, hasLength(2));
  });

  test('unsafe image paths, redirects, and oversized images never become previews',
      () async {
    final unsafe = deviceJson()
      ..['image_path'] = 'https://elsewhere.example/collect-token';
    expect(() => ScreenWallDevice.fromJson(unsafe), throwsFormatException);
    final visited = <Uri>[];
    final client = ScreenWallClient(
      const ScreenWallConfig(
          apiUrl: 'https://preview.example.com', viewerToken: 'viewer-secret'),
      client: MockClient((request) async {
        visited.add(request.url);
        expect(request.url.host, 'preview.example.com');
        expect(request.followRedirects, isFalse);
        if (request.url.path == '/api/previews') {
          return http.Response('', 302,
              headers: {'location': 'https://elsewhere.example/collect-token'});
        }
        return http.Response.bytes(
            List.filled(screenWallMaximumImageBytes + 1, 0), 200);
      }),
    );
    addTearDown(client.close);
    await expectLater(client.loadDevices(), throwsA(isA<ScreenWallApiException>()));
    final images = await client
        .loadImages([ScreenWallDevice.fromJson(deviceJson())], {});
    expect(images.images, isEmpty);
    expect(images.failures, {'123456789'});
    expect(visited, hasLength(2));
  });
}
