import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

http.Client createScreenWallHttpClient(String caPem) {
  final context = SecurityContext(withTrustedRoots: true);
  if (caPem.trim().isNotEmpty) {
    context.setTrustedCertificatesBytes(utf8.encode(caPem));
  }
  return IOClient(HttpClient(context: context));
}
