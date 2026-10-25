import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// GitHub 的「猫」图标
///
/// 直接渲染 `assets/github.svg`（simple-icons 的 GitHub mark，viewBox 0 0 24 24）。
/// Flutter 的 `Image` 不支持 SVG，用 [SvgPicture.asset]（flutter_svg）绘制矢量，
/// 任意尺寸都清晰；[colorFilter] 让图标跟随主题色。
class GithubMark extends StatelessWidget {
  final double size;
  final Color? color;
  const GithubMark({super.key, this.size = 20, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? IconTheme.of(context).color ?? Colors.white;
    return SvgPicture.asset(
      'assets/github.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
      // 允许它在 AppBar/ListTile 里正常参与布局
      fit: BoxFit.contain,
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }
}
