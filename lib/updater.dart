import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'version.dart';

/// 更新检查：直连 GitHub REST API 读 **最新正式 Release**，与本机 [kAppVersion] 比较。
///
/// 设计取舍：
/// * 只用 `dart:io` 的 HttpClient，不引第三方包（仓库只依赖 flutter_svg）；
/// * 只查 `releases/latest`（GitHub 保证它是最新的**非 draft / 非 prerelease**），
///   仓库里只有预发布时会 404，此时退回 `releases?per_page=10` 取第一个非 draft；
/// * 任何失败都变成 [UpdateCheck.error] 里的人话，**绝不抛异常**——
///   更新检查只是锦上添花，网络不通不能影响越狱主流程。
///
/// 注意：release 的 APK 是发布 Release 后由 CI 挂上去的，
/// 所以「刚发完 Release 的几十秒内」拿到的资产可能为空，界面要按「还没挂包」处理。

/// 仓库 slug（与 main.dart 的 kRepoUrl / AppBar 里的主页按钮同一个仓库）
const String kGitHubRepoSlug = 'No-World/rootkit';

/// Releases API（列表 / 最新）
const String kReleasesApiUrl =
    'https://api.github.com/repos/$kGitHubRepoSlug/releases';

/// Release 页面（拿不到 API 时给用户手点的兜底入口）
const String kReleasesPageUrl =
    'https://github.com/$kGitHubRepoSlug/releases/latest';

/// 一个 GitHub Release 中更新检查需要的字段
class GitHubRelease {
  /// 原始 tag，如 `v1.0.18`
  final String tag;

  /// 去掉前缀的版本号，如 `1.0.18`（用于比较与显示）
  final String version;

  /// Release 标题（可能是空串）
  final String name;

  /// 更新说明（Markdown 原文）
  final String body;

  /// Release 网页地址
  final String htmlUrl;

  /// APK 资产直链（CI 还没挂包时为空串）
  final String apkUrl;

  /// APK 文件名，如 `RootKit-v1.0.18.apk`
  final String apkName;

  /// APK 字节数（未知为 0）
  final int apkSize;

  /// 发布时间（ISO8601 字符串，直接展示）
  final String publishedAt;

  /// 是否为预发布（PR 测试包会发成 prerelease）
  final bool prerelease;

  const GitHubRelease({
    required this.tag,
    required this.version,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.apkUrl,
    required this.apkName,
    required this.apkSize,
    required this.publishedAt,
    required this.prerelease,
  });

  factory GitHubRelease.fromJson(Map<String, dynamic> j) {
    final tag = (j['tag_name'] as String?)?.trim() ?? '';
    final assets = (j['assets'] as List?) ?? const [];
    var apkUrl = '';
    var apkName = '';
    var apkSize = 0;
    for (final a in assets) {
      if (a is! Map) continue;
      final n = (a['name'] as String?) ?? '';
      // 只认 .apk 本体；跳过 `*.apk.md5` 这类旁挂文件
      if (!n.toLowerCase().endsWith('.apk')) continue;
      apkUrl = (a['browser_download_url'] as String?) ?? '';
      apkName = n;
      apkSize = (a['size'] as num?)?.toInt() ?? 0;
      break;
    }
    return GitHubRelease(
      tag: tag,
      version: normalizeVersion(tag),
      name: (j['name'] as String?)?.trim() ?? '',
      body: (j['body'] as String?) ?? '',
      htmlUrl: (j['html_url'] as String?) ?? kReleasesPageUrl,
      apkUrl: apkUrl,
      apkName: apkName,
      apkSize: apkSize,
      publishedAt:
          (j['published_at'] as String?) ?? (j['created_at'] as String?) ?? '',
      prerelease: j['prerelease'] == true,
    );
  }

  /// 给弹窗用的说明摘要：去掉 Markdown 里最吵的符号，并限行 / 限字
  ///
  /// 不做完整 Markdown 渲染（那是另一个依赖）；Release 说明基本是
  /// `## 标题` + `- 列表`，去符号后直接读就够。
  String summary({int maxLines = 14, int maxChars = 1400}) {
    final lines = <String>[];
    for (final raw in body.split('\n')) {
      var l = raw.trimRight();
      if (l.trim().isEmpty) {
        // 空行最多留一个，避免摘要里大片空白
        if (lines.isNotEmpty && lines.last.isNotEmpty) lines.add('');
        continue;
      }
      if (RegExp(r'^\s*<!--').hasMatch(l)) continue; // HTML 注释
      l = l.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ''); // 图片
      // 链接 → 只留文字（Dart 的 replaceAll 不展开 $1，必须用 replaceAllMapped）
      l = l.replaceAllMapped(
          RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '');
      l = l.replaceAll(RegExp(r'^\s*#{1,6}\s*'), ''); // 标题
      l = l.replaceAll(RegExp(r'^\s*[-*+]\s+'), '· '); // 列表
      l = l.replaceAll(RegExp(r'^\s*>\s*'), ''); // 引用
      l = l.replaceAll(RegExp(r'^\s*\|'), ''); // 表格行首
      l = l.replaceAll('**', '').replaceAll('`', '').replaceAll('~~', '');
      if (l.trim().isEmpty) continue;
      lines.add(l.trim());
    }
    var out = lines.join('\n').trim();
    if (out.length > maxChars) {
      out = '${out.substring(0, maxChars)}…';
    }
    final ls = out.split('\n');
    if (ls.length > maxLines) {
      out = '${ls.take(maxLines).join('\n')}\n…';
    }
    return out;
  }
}

/// 一次更新检查的结果（失败时 [latest] 为 null、[error] 有原因）
class UpdateCheck {
  /// 本机版本（来自 [kAppVersion]）
  final String current;

  /// 最新正式 Release（查不到为 null）
  final GitHubRelease? latest;

  /// 失败原因（人话，可直接显示）
  final String? error;

  /// 本次检查时间
  final DateTime at;

  const UpdateCheck({
    required this.current,
    this.latest,
    this.error,
    required this.at,
  });

  bool get ok => error == null && latest != null;

  /// 有新版本可装
  bool get hasUpdate =>
      latest != null && compareVersions(latest!.version, current) > 0;

  /// 已是最新（检查成功且没有更新）
  bool get upToDate => ok && !hasUpdate;

  String get latestVersion => latest?.version ?? '';

  /// 一行状态（选项弹窗里显示）
  String get statusLine {
    if (error != null) return '检查失败：$error';
    final v = latestVersion;
    if (v.isEmpty) return '检查失败：返回内容里没有版本号';
    if (hasUpdate) {
      final size =
          latest!.apkSize > 0 ? ' · 安装包 ${formatBytes(latest!.apkSize)}' : '';
      return '有新版 v$v（当前 v$current）$size';
    }
    // 本机比线上还新（自己编的测试包 / 刚提交还没发 Release）——不要误报「已是最新」
    if (compareVersions(v, current) < 0) {
      return '线上最新 v$v，本机 v$current（比线上新）';
    }
    return '已是最新（v$current）';
  }
}

/// 去掉版本号里的 `v` 前缀与 `-prtest` / `+10018` 之类的后缀
String normalizeVersion(String tag) {
  var s = tag.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  final cut = s.indexOf(RegExp(r'[-+]'));
  if (cut >= 0) s = s.substring(0, cut);
  return s.trim();
}

/// 版本比较：按 `.` 分段比数字（`1.0.9 < 1.0.17`，字符串比较会错）
///
/// 返回 -1 / 0 / 1。缺的段按 0 处理；非数字段按 0 处理（只影响极端 tag）。
int compareVersions(String a, String b) {
  final pa = _versionSegments(a);
  final pb = _versionSegments(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

List<int> _versionSegments(String v) {
  final s = normalizeVersion(v);
  if (s.isEmpty) return const [0];
  return s.split('.').map((e) {
    final m = RegExp(r'^\d+').firstMatch(e.trim());
    if (m == null) return 0;
    return int.tryParse(m.group(0)!) ?? 0;
  }).toList();
}

/// 字节数 → 人话（19.0MB）
String formatBytes(int n) {
  if (n <= 0) return '未知大小';
  const kb = 1024.0;
  if (n < kb * 1024) return '${(n / kb).toStringAsFixed(0)}KB';
  if (n < kb * kb * 1024) return '${(n / kb / kb).toStringAsFixed(1)}MB';
  return '${(n / kb / kb / kb).toStringAsFixed(2)}GB';
}

/// 内部：带 HTTP 状态码的响应
class _Resp {
  final int status;
  final String body;
  const _Resp(this.status, this.body);
}

/// 内部：把可以显示给用户的失败原因抛出来
class UpdateCheckException implements Exception {
  final String message;
  const UpdateCheckException(this.message);
  @override
  String toString() => message;
}

/// 检查 GitHub 上的最新 Release（**不抛异常**，失败原因在 [UpdateCheck.error]）
///
/// [client] 仅供测试注入；不传则自建并在结束时关闭。
Future<UpdateCheck> checkForUpdate({
  String current = kAppVersion,
  Duration timeout = const Duration(seconds: 12),
  HttpClient? client,
}) async {
  final owned = client == null;
  final c =
      client ?? (HttpClient()..connectionTimeout = const Duration(seconds: 8));
  try {
    final latest = await _fetchLatest(c, timeout);
    return UpdateCheck(current: current, latest: latest, at: DateTime.now());
  } on UpdateCheckException catch (e) {
    return UpdateCheck(current: current, error: e.message, at: DateTime.now());
  } catch (e) {
    return UpdateCheck(
        current: current, error: friendlyNetworkError(e), at: DateTime.now());
  } finally {
    if (owned) {
      try {
        c.close(force: true);
      } catch (_) {}
    }
  }
}

/// 把底层异常翻译成用户能看懂的一句话（日志里也能直接贴）
String friendlyNetworkError(Object e) {
  if (e is TimeoutException) return '请求超时（GitHub 无响应）';
  if (e is SocketException) {
    // 国产 ROM 常见：没给本 App 联网权限 / 网络被拦 / 无 DNS
    final m = e.osError?.message ?? e.message;
    return '网络不可用（$m）';
  }
  if (e is HandshakeException) return 'TLS 握手失败（网络被拦截？）';
  if (e is FormatException) return '返回内容不是 JSON（可能被网络中间页拦截）';
  if (e is HttpException) return 'HTTP 错误：${e.message}';
  return e.toString();
}

Future<GitHubRelease> _fetchLatest(HttpClient c, Duration timeout) async {
  // 1) 首选 /releases/latest：GitHub 保证是最新的正式版（PR 预发布天然被排除）
  final r = await _get(c, Uri.parse('$kReleasesApiUrl/latest'), timeout);
  if (r.status == 200) {
    final j = jsonDecode(r.body);
    if (j is! Map) throw const UpdateCheckException('返回内容格式不对（期望对象）');
    final rel = GitHubRelease.fromJson(j.cast<String, dynamic>());
    if (rel.version.isEmpty) {
      throw const UpdateCheckException('返回内容里没有 tag_name');
    }
    return rel;
  }
  if (r.status != 404) {
    throw UpdateCheckException(
        'GitHub API 返回 HTTP ${r.status}${_httpHint(r.status)}');
  }

  // 2) 仓库里只有预发布时 /latest 是 404 → 退回列表取第一个非 draft
  final l = await _get(c, Uri.parse('$kReleasesApiUrl?per_page=10'), timeout);
  if (l.status != 200) {
    throw UpdateCheckException(
        'GitHub API 返回 HTTP ${l.status}${_httpHint(l.status)}');
  }
  final arr = jsonDecode(l.body);
  if (arr is! List) throw const UpdateCheckException('返回内容格式不对（期望数组）');
  for (final e in arr) {
    if (e is! Map) continue;
    if (e['draft'] == true) continue;
    final rel = GitHubRelease.fromJson(e.cast<String, dynamic>());
    if (rel.version.isNotEmpty) return rel;
  }
  throw const UpdateCheckException('仓库里还没有可用的 Release');
}

String _httpHint(int status) {
  if (status == 403 || status == 429) return '（可能被 API 限流，稍后再试）';
  if (status == 401) return '（仓库需要登录才能看？）';
  if (status >= 500) return '（GitHub 服务端问题，稍后再试）';
  return '';
}

Future<_Resp> _get(HttpClient c, Uri uri, Duration timeout) async {
  final req = await c.getUrl(uri).timeout(timeout);
  // GitHub API 强制要求 User-Agent，缺了直接 403
  req.headers.set('User-Agent', 'RootKit/$kAppVersion (+$kReleasesPageUrl)');
  req.headers.set('Accept', 'application/vnd.github+json');
  req.headers.set('X-GitHub-Api-Version', '2022-11-28');
  final resp = await req.close().timeout(timeout);
  final body = await resp
      .transform(const Utf8Decoder(allowMalformed: true))
      .join()
      .timeout(timeout);
  return _Resp(resp.statusCode, body);
}
