/// known_kernels.dart — 内核版本 → 物理基址 的内置记录表
///
/// 设计（用户要求）：
///   * 物理基址是**跟内核镜像绑定**的常量，不该每次运行都去探测；
///   * 已知内核直接命中记录（跳过 /proc/iomem 探测）；
///   * 未知内核在「环境检查」阶段**拦住**，要求手填 / 提供 boot.img 计算，
///     手填后会按内核版本存成"自定义记录"，下次同内核直接通过。
class KnownKernel {
  /// /proc/version 里的版本 token，例如
  /// `6.12.58-android16-6-g3a7ac1674240-abogki541502914`
  final String version;

  /// 内核镜像物理加载基址（对应链接期 _text = 0xffffffc080000000）
  final int physBase;

  /// selinux_state 相对 _stext 的偏移
  final int selinuxStateOffset;

  /// module_layout 的 MODVERSIONS CRC（装载任意带 `__versions` 的 .ko 都需要）
  final int moduleLayoutCrc;

  /// 说明 / 来源
  final String note;

  const KnownKernel({
    required this.version,
    required this.physBase,
    this.selinuxStateOffset = 0x27D7A60,
    this.moduleLayoutCrc = 0x797f2b3e,
    this.note = '',
  });
}

/// 内置记录（每验证一个内核就往这里加一条）
const List<KnownKernel> kKnownKernels = [
  KnownKernel(
    version: '6.12.58-android16-6-g3a7ac1674240-abogki541502914',
    physBase: 0xC7800000,
    selinuxStateOffset: 0x27D7A60,
    note: 'MagicOS 11.0.0.110 (MLY-AN00) — .107/.110 内核逐字节相同；'
        '由 xbl_config/uefi 推导，并经 /proc/iomem + kallsyms 交叉验证',
  ),
];

/// 从 /proc/version 内容里取版本 token
String parseKernelVersion(String procVersion) {
  final m = RegExp(r'Linux version (\S+)').firstMatch(procVersion);
  return m?.group(1) ?? '';
}

/// 查表：先精确匹配，再按去掉 `-4k` 之类后缀的宽松前缀匹配
KnownKernel? lookupKernel(String token) {
  if (token.isEmpty) return null;
  for (final k in kKnownKernels) {
    if (k.version == token) return k;
  }
  // 宽松匹配：内核版本主体（到 `-4k`/` SMP` 之前）相同即算同一镜像
  String norm(String s) {
    var t = s;
    for (final suf in ['-4k', '-8k', '-16k']) {
      if (t.endsWith(suf)) t = t.substring(0, t.length - suf.length);
    }
    return t;
  }

  final n = norm(token);
  for (final k in kKnownKernels) {
    if (norm(k.version) == n) return k;
  }
  return null;
}
