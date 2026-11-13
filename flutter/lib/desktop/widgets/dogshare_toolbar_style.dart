import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

enum DogShareToolbarSymbol {
  pin,
  display,
  mode,
  communication,
  record,
  disconnect
}

class DogShareToolbarStyle {
  static const ink = Color(0xFF30383C);
  static const background = Color(0xFFF8F8F5);
  static const border = Color(0xFFDEDFD9);
  static const hover = Color(0xFFEAEEE9);
  static const selected = Color(0xFFDFEDE6);
  static const selectedHover = Color(0xFFD1E5DA);
  static const accent = Color(0xFF2A9687);
  static const waiting = Color(0xFFFFF2DA);
  static const waitingHover = Color(0xFFF6E8C9);
  static const recording = Color(0xFFFCE8E4);
  static const recordingHover = Color(0xFFF6DAD4);
  static const danger = Color(0xFFD7635A);
  static const radius = BorderRadius.all(Radius.circular(12));
}

class DogShareToolbarFrame extends StatelessWidget {
  const DogShareToolbarFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: DogShareToolbarStyle.background,
          border: Border.all(color: DogShareToolbarStyle.border),
          borderRadius: DogShareToolbarStyle.radius,
        ),
        child: child,
      );
}

class DogShareToolbarDivider extends StatelessWidget {
  const DogShareToolbarDivider({super.key, required this.horizontalToolbar});

  final bool horizontalToolbar;

  @override
  Widget build(BuildContext context) => Container(
        width: horizontalToolbar ? 1 : 20,
        height: horizontalToolbar ? 20 : 1,
        margin: horizontalToolbar
            ? const EdgeInsets.symmetric(horizontal: 5)
            : const EdgeInsets.symmetric(vertical: 5),
        color: DogShareToolbarStyle.border,
      );
}

class DogShareToolbarIcon extends StatelessWidget {
  const DogShareToolbarIcon({
    super.key,
    required this.symbol,
    this.active = false,
    this.enabled = true,
  });

  final DogShareToolbarSymbol symbol;
  final bool active;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Opacity(
            opacity: enabled ? 1 : 0.38,
            child: SvgPicture.asset(
              'assets/dogshare_toolbar_${symbol.name}.svg',
              width: symbol == DogShareToolbarSymbol.record ? 30 : 23,
              height: 23,
              colorFilter: active
                  ? ColorFilter.mode(
                      symbol == DogShareToolbarSymbol.record
                          ? DogShareToolbarStyle.danger
                          : DogShareToolbarStyle.accent,
                      BlendMode.srcIn,
                    )
                  : null,
              excludeFromSemantics: true,
            ),
          ),
        ),
      );
}
