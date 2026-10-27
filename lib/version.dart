/// App 版本号（唯一来源）
///
/// 同时被三处使用：标题栏显示、日志 `[diag:*] ver=` 行、与 pubspec.yaml 的 version 保持一致。
/// 改版本时这里和 pubspec.yaml 必须同步（CHANGELOG 也一起改）。
const String kAppVersion = '1.0.18';

/// 与本仓库 `assets/ksu_template.ko.gz` 同源的 KernelSU 管理器版本。
///
/// 模板 .ko 来自 KernelSU v3.3.1 官方 6.12 LKM（只改写了 vermagic），
/// 管理器的用户态协议要与内核侧一致，所以**管理器版本要跟模板对得上**：
/// 版本不符时不阻塞（多数 3.3.x 兼容），但会在日志里警告并要求确认。
const String kKsuManagerVersion = '3.3.1';
