import 'package:http/http.dart' as http;

http.Client createScreenWallHttpClient(String caPem) {
  if (caPem.trim().isNotEmpty) {
    throw const FormatException('自定义 CA 证书需要使用桌面客户端');
  }
  return http.Client();
}
