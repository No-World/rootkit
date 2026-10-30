/// known_kernels.dart — 内核版本 → 标定常量 的内置记录表
///
/// 设计（用户要求）：
///   * 物理基址/链接基址是**跟内核镜像绑定**的常量，不该每次运行都去探测；
///   * 链接基址与 `_stext-_text` 间距逐内核记录（已标定的两个内核恰好都是
///     linkBase=0xffffffc080000000 / gap=0x10000，但不应把它当成定律写死在
///     calib/ksupatch 里）；
///   * 已知内核直接命中记录（跳过 /proc/iomem 探测）；
///   * 未知内核在「环境检查」阶段**拦住**，要求手填 / 提供 boot.img 计算，
///     手填后会按内核版本存成"自定义记录"，下次同内核直接通过。
///
/// 与内核强绑定的 APK 资产（符号表 / 自制模块 / KSU LKM 模板）也在这里按
/// 内核指定 —— chain.dart 不再写死资产文件名。
class KnownKernel {
  /// /proc/version 里的版本 token（惯例：不带 `-4k` 后缀），例如
  /// `6.12.58-android16-6-g3a7ac1674240-abogki541502914`
  final String version;

  /// 内核镜像物理加载基址（对应链接期 _text）
  final int physBase;

  /// 链接期 _text 虚拟地址（KASLR slide 的计算锚点：
  /// slide = 泄漏的运行时 _text − textLinkBase）。
  /// 已标定的荣耀内核均为 0xffffffc080000000（GKI 惯例），仍逐内核记录。
  final int textLinkBase;

  /// selinux_state 相对 _text 的偏移（镜像 kallsyms/BTF 提取）
  final int selinuxStateOffset;

  /// module_layout 的 MODVERSIONS CRC（装载任意带 `__versions` 的 .ko 都需要）
  final int moduleLayoutCrc;

  /// _stext 相对 _text 的偏移（/proc/iomem「Kernel code」从 _stext 起，
  /// 兜底探测要减掉；MLY=0x10000，C901=0）
  final int textStextGap;

  /// 离线符号表 APK 资产名（null = 默认 6.12 资产，兼容旧记录）
  final String? symtabAsset;

  /// 自制模块 APK 资产名（null = 默认 6.12 模块）
  final String? moduleAsset;

  /// KSU LKM 模板 APK 资产名（.gz；null = 默认 6.12 模板）
  final String? ksuAsset;

  /// 说明 / 来源
  final String note;

  const KnownKernel({
    required this.version,
    required this.physBase,
    required this.textLinkBase,
    this.selinuxStateOffset = 0x27E7A60,
    this.moduleLayoutCrc = 0x797f2b3e,
    this.textStextGap = 0x10000,
    this.symtabAsset,
    this.moduleAsset,
    this.ksuAsset,
    this.note = '',
  });
}

/// 内置记录（每验证一个内核就往这里加一条）
const List<KnownKernel> kKnownKernels = [
  // —— Magic9 (MLY-AN00) · MagicOS 11.0.0.110 —— 6.12.58 android16-6
  KnownKernel(
    version: '6.12.58-android16-6-g3a7ac1674240-abogki541502914',
    physBase: 0xC7800000,
    textLinkBase: 0xffffffc080000000,
    // 0x27E7A60 = 旧记录值 0x27D7A60(_stext 相对) + 0x10000(gap)
    selinuxStateOffset: 0x27E7A60,
    note: 'MagicOS 11.0.0.110 (MLY-AN00) — .107/.110 内核逐字节相同；'
        '由 xbl_config/uefi 推导，并经 /proc/iomem + kallsyms 交叉验证',
  ),
  // —— Honor 600 (C901E4H) · MagicOS 11.0.0.121 —— 6.6.118 android15-8
  // 标定来源：issue #1 提供的全量固件（update_full_base.zip v923615）
  //   physBase        ← xbl_config FDT（ghostlock-extract）
  //   textLinkBase    ← 镜像 kallsyms 恢复（relative_base = 0xffffffc080000000，与 MLY 同）
  //   selinux/CRC/BTF ← 镜像 kallsyms + BTF + vendor_boot 504×.ko 众数
  //   （注意：分析镜像时必须设 GHOSTLOCK_NO_PROC_KALLSYMS=1，否则工具会
  //    读到宿主 Linux 的 /proc/kallsyms，把 WSL 内核的符号当成目标内核的）
  KnownKernel(
    version: '6.6.118-android15-8-gc901ea41aa32-ab15981388',
    physBase: 0xA8000000,
    textLinkBase: 0xffffffc080000000,
    selinuxStateOffset: 0x236A2E0,
    moduleLayoutCrc: 0x4e276f37,
    textStextGap: 0x10000,
    symtabAsset: 'assets/kallsyms_6.6.118_c901.bin.gz',
    moduleAsset: 'assets/module_6.6.ko',
    ksuAsset: 'assets/ksu_template_6.6.ko.gz',
    note: 'Honor 600 (C901E4H) MagicOS 11.0.0.121 — 离线标定（issue #1 固件），'
        '待真机复核；KSU 用官方 android15-6.6 LKM',
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
  String norm(String s) {
    var t = s;
    for (final suf in ['-4k', '-8k', '-16k']) {
      if (t.endsWith(suf)) t = t.substring(0, t.length - suf.length);
    }
    return t;
  }

  final n = norm(token);
  for (final k in kKnownKernels) {
    if (k.version == token || norm(k.version) == n) return k;
  }
  return null;
}
