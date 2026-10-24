import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

enum OneYesSyncStatus {
  success,
  uploadedInitial,
  merged,
  pulled,
  pushed,
  error,
}

class OneYesSyncResult {
  final OneYesSyncStatus status;
  final int version;
  final Map<String, dynamic>? config;
  final String? message;

  OneYesSyncResult({
    required this.status,
    this.version = 0,
    this.config,
    this.message,
  });
}

/// OneYes 配置中心官方 Flutter/Dart 客户端
/// 严格遵循 OneYes 架构规范：零知识端到端加密 (E2EE)、PBKDF2-HMAC-SHA256 密钥派生、AES-256-GCM 加密
class OneYesClient {
  final String serverUrl;
  final String email;
  final String appName;
  late final String authKeyB64;
  late final SecretKey dataKey;
  bool _initialized = false;

  OneYesClient({
    String? serverUrl,
    required String email,
    String appName = 'rustdesk',
  })  : serverUrl = (serverUrl ?? 'http://192.168.10.66:8890')
            .trim()
            .replaceAll(RegExp(r'/+$'), ''),
        email = email.trim().toLowerCase(),
        appName = appName.trim();

  /// 密钥派生 (必须在调用 pull/push/sync 前执行一次)
  Future<void> init(String password) async {
    final pwdBytes = utf8.encode(password);
    final secretKey = SecretKey(pwdBytes);

    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );

    // 1. 认证 Key（发送至 Header X-Auth-Key 用于服务端鉴权）
    final authNonce = utf8.encode('oneyes_auth_$email');
    final authDerived =
        await kdf.deriveKey(secretKey: secretKey, nonce: authNonce);
    final authKeyBytes = await authDerived.extractBytes();
    authKeyB64 = base64.encode(authKeyBytes);

    // 2. 数据加解密 Key（AES-256-GCM 密钥，纯本地保留，不出网）
    final dataNonce = utf8.encode('oneyes_data_$email');
    dataKey = await kdf.deriveKey(secretKey: secretKey, nonce: dataNonce);

    _initialized = true;
  }

  void _checkInit() {
    if (!_initialized) {
      throw StateError('OneYesClient 未初始化，请先调用 client.init(password)');
    }
  }

  /// AES-256-GCM 数据加密 -> Base64(12字节 Nonce + Ciphertext + 16字节 Tag)
  Future<String> encrypt(Map<String, dynamic> dataDict) async {
    _checkInit();
    final aesGcm = AesGcm.with256bits();
    final plaintext = utf8.encode(json.encode(dataDict));

    final secretBox = await aesGcm.encrypt(
      plaintext,
      secretKey: dataKey,
    );

    final combined = Uint8List(secretBox.nonce.length +
        secretBox.cipherText.length +
        secretBox.mac.bytes.length);
    int offset = 0;
    combined.setRange(offset, offset + secretBox.nonce.length, secretBox.nonce);
    offset += secretBox.nonce.length;
    combined.setRange(
        offset, offset + secretBox.cipherText.length, secretBox.cipherText);
    offset += secretBox.cipherText.length;
    combined.setRange(
        offset, offset + secretBox.mac.bytes.length, secretBox.mac.bytes);

    return base64.encode(combined);
  }

  /// AES-256-GCM 数据解密
  Future<Map<String, dynamic>> decrypt(String encryptedB64) async {
    _checkInit();
    final raw = base64.decode(encryptedB64);
    if (raw.length < 28) {
      throw const FormatException('密文长度异常，无法解密');
    }

    final nonce = raw.sublist(0, 12);
    final ciphertext = raw.sublist(12, raw.length - 16);
    final mac = raw.sublist(raw.length - 16);

    final aesGcm = AesGcm.with256bits();
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: Mac(mac));

    final decryptedBytes = await aesGcm.decrypt(secretBox, secretKey: dataKey);
    final decodedStr = utf8.decode(decryptedBytes);
    return json.decode(decodedStr) as Map<String, dynamic>;
  }

  /// HTTP 请求封装
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    _checkInit();
    final uri = Uri.parse('$serverUrl$path');
    final headers = {
      'Content-Type': 'application/json',
      'X-Email': email,
      'X-Auth-Key': authKeyB64,
    };

    http.Response resp;
    try {
      if (method == 'GET') {
        resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 10));
      } else if (method == 'POST') {
        resp = await http
            .post(
              uri,
              headers: headers,
              body: body != null ? json.encode(body) : null,
            )
            .timeout(const Duration(seconds: 10));
      } else if (method == 'DELETE') {
        resp = await http.delete(uri, headers: headers).timeout(const Duration(seconds: 10));
      } else {
        throw UnsupportedError('不支持的 HTTP 方法: $method');
      }
    } catch (e) {
      throw RuntimeErrorException('无法连接 OneYes 配置中心服务器 ($serverUrl): $e');
    }

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      if (resp.body.isEmpty) return {};
      return json.decode(resp.body) as Map<String, dynamic>;
    } else {
      String detail = resp.body;
      try {
        final errJson = json.decode(resp.body);
        if (errJson is Map && errJson['detail'] != null) {
          detail = errJson['detail'].toString();
        }
      } catch (_) {}
      throw RuntimeErrorException('OneYes 服务端错误 [${resp.statusCode}]: $detail');
    }
  }

  /// 注册新账号
  Future<Map<String, dynamic>> register() async {
    _checkInit();
    final uri = Uri.parse('$serverUrl/api/auth/register');
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email, 'auth_key': authKeyB64}),
    );
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return json.decode(resp.body) as Map<String, dynamic>;
    }
    throw RuntimeErrorException('注册失败 [${resp.statusCode}]: ${resp.body}');
  }

  /// 验证登录
  Future<bool> login() async {
    _checkInit();
    final uri = Uri.parse('$serverUrl/api/auth/login');
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'email': email, 'auth_key': authKeyB64}),
    );
    return resp.statusCode == 200;
  }

  /// 从服务器拉取并解密最新配置
  Future<({Map<String, dynamic>? config, int version})> pull() async {
    final res = await _request('GET', '/api/config/$appName');
    final exists = res['exists'] == true;
    final encData = res['encrypted_data'] as String?;
    final version = (res['version'] as num?)?.toInt() ?? 0;

    if (!exists || encData == null || encData.isEmpty) {
      return (config: null, version: 0);
    }

    final decrypted = await decrypt(encData);
    return (config: decrypted, version: version);
  }

  /// 加密并推送到服务器，保存为新版本
  Future<int> push(Map<String, dynamic> config,
      {String remark = 'RustDesk client update'}) async {
    final encData = await encrypt(config);
    final res = await _request('POST', '/api/config/$appName', body: {
      'encrypted_data': encData,
      'remark': remark,
    });
    return (res['version'] as num?)?.toInt() ?? 0;
  }

  /// 递归深度合并两个字典 (Map)
  static Map<String, dynamic> deepMerge(
      Map<String, dynamic> base, Map<String, dynamic> override) {
    final merged = Map<String, dynamic>.from(base);
    for (final entry in override.entries) {
      final key = entry.key;
      final val = entry.value;
      if (merged.containsKey(key) &&
          merged[key] is Map<String, dynamic> &&
          val is Map<String, dynamic>) {
        merged[key] = deepMerge(
            merged[key] as Map<String, dynamic>, val);
      } else {
        merged[key] = val;
      }
    }
    return merged;
  }

  /// 比较两个 Map 内容是否一致 (用于判断是否需要回推)
  static bool mapEquals(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key)) return false;
      final va = a[key];
      final vb = b[key];
      if (va is Map<String, dynamic> && vb is Map<String, dynamic>) {
        if (!mapEquals(va, vb)) return false;
      } else if (va != vb) {
        return false;
      }
    }
    return true;
  }
}

class RuntimeErrorException implements Exception {
  final String message;
  RuntimeErrorException(this.message);

  @override
  String toString() => message;
}
