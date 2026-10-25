import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class ShellResult {
  final int code;
  final String out;
  final String err;
  final String via;

  const ShellResult(this.code, this.out, this.err, [this.via = '']);

  String get all => (out + err).trimRight();

  @override
  String toString() => 'rc=$code\n$all';
}

/// Shizuku shell 通道（Kotlin 侧用 Shizuku.newProcess 以 shell 身份执行）
class ShizukuShell {
  static const MethodChannel _ch = MethodChannel('rootkit/shizuku');

  static Future<bool> checkPermission() async {
    try {
      return await _ch.invokeMethod<bool>('check') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestPermission({Duration timeout = const Duration(seconds: 20)}) async {
    try {
      final r = await _ch
          .invokeMethod<bool>('request')
          .timeout(timeout, onTimeout: () => false);
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<ShellResult> run(
    String cmd, {
    Uint8List? stdin,
    int timeoutMs = 120000,
  }) async {
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('run', {
        'cmd': cmd,
        'stdin': stdin == null ? null : base64Encode(stdin),
        'timeoutMs': timeoutMs,
      });
      final code = (m?['code'] as num?)?.toInt() ?? -1;
      final out = (m?['out'] as String?) ?? '';
      final err = (m?['err'] as String?) ?? '';
      final via = (m?['via'] as String?) ?? '';
      return ShellResult(code, out, err, via);
    } catch (e) {
      return ShellResult(-1, '', 'channel error: $e');
    }
  }

  static Future<bool> openApp(String pkg) async {
    try {
      return await _ch.invokeMethod<bool>('openApp', {'pkg': pkg}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 用系统浏览器打开链接（GitHub 仓库等）
  static Future<bool> openUrl(String url) async {
    try {
      return await _ch.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 把 APK 内的图片保存到相册（Android 10+ 无需存储权限）
  static Future<String> saveImage(String asset, String name) async {
    try {
      return await _ch.invokeMethod<String>('saveImage',
              {'asset': asset, 'name': name}) ??
          'save fail';
    } catch (e) {
      return 'save fail: $e';
    }
  }

  static Future<String> filesDir() async {
    try {
      return await _ch.invokeMethod<String>('filesDir') ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<String?> getPref(String key) async {
    try {
      return await _ch.invokeMethod<String>('getPref', {'key': key});
    } catch (_) {
      return null;
    }
  }

  static Future<void> setPref(String key, String value) async {
    try {
      await _ch.invokeMethod('setPref', {'key': key, 'value': value});
    } catch (_) {}
  }
}
