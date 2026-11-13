import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';

class SubtitleColorSwatch extends StatelessWidget {
  const SubtitleColorSwatch({
    super.key,
    required this.color,
    this.size = 26,
    this.radius = 3,
  });

  final Color color;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: CustomPaint(
            painter: const _ColorCheckerboard(),
            child: ColoredBox(color: color),
          ),
        ),
      );
}

class DogShareSubtitleColorPicker extends StatefulWidget {
  const DogShareSubtitleColorPicker({
    super.key,
    required this.initialColor,
    required this.onConfirm,
    required this.onCancel,
  });

  final Color initialColor;
  final ValueChanged<Color> onConfirm;
  final VoidCallback onCancel;

  @override
  State<DogShareSubtitleColorPicker> createState() =>
      _DogShareSubtitleColorPickerState();
}

class _DogShareSubtitleColorPickerState
    extends State<DogShareSubtitleColorPicker> {
  late HSVColor _color = HSVColor.fromColor(widget.initialColor);
  late final _channels = List.generate(
    4,
    (index) => TextEditingController(text: _rgbaValues()[index].toString()),
  );

  List<int> _rgbaValues() {
    final color = _color.toColor();
    return [color.red, color.green, color.blue, (_color.alpha * 100).round()];
  }

  @override
  void dispose() {
    for (final controller in _channels) {
      controller.dispose();
    }
    super.dispose();
  }

  void _setColor(HSVColor color, {int? editingChannel}) {
    setState(() => _color = color);
    final channels = _rgbaValues();
    for (var index = 0; index < _channels.length; index++) {
      final value = channels[index].toString();
      if (index != editingChannel && _channels[index].text != value) {
        _channels[index].text = value;
      }
    }
  }

  void _setChannel(int index, String text) {
    final value = int.tryParse(text);
    if (value == null) return;
    if (index == 3) {
      _setColor(_color.withAlpha(value.clamp(0, 100) / 100),
          editingChannel: index);
    } else {
      final channels = _rgbaValues();
      channels[index] = value.clamp(0, 255);
      _setColor(
        HSVColor.fromColor(Color.fromARGB((_color.alpha * 255).round(),
            channels[0], channels[1], channels[2])),
        editingChannel: index,
      );
    }
  }

  Widget _saturationValuePicker() => SizedBox(
        height: 220,
        child: LayoutBuilder(
          builder: (context, constraints) {
            void select(Offset position) => _setColor(
                  _color
                      .withSaturation(
                          (position.dx / constraints.maxWidth).clamp(0.0, 1.0))
                      .withValue((1 - position.dy / constraints.maxHeight)
                          .clamp(0.0, 1.0)),
                );

            return Semantics(
              label: 'HSV',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanDown: (event) => select(event.localPosition),
                onPanUpdate: (event) => select(event.localPosition),
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [
                          Colors.white,
                          HSVColor.fromAHSV(1, _color.hue, 1, 1).toColor(),
                        ]),
                      ),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Colors.black],
                        ),
                      ),
                    ),
                    Positioned(
                      left: _color.saturation * constraints.maxWidth - 8,
                      top: (1 - _color.value) * constraints.maxHeight - 8,
                      child: IgnorePointer(
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: _color.withAlpha(1).toColor(),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black54, blurRadius: 2),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );

  Widget _slider({
    required String label,
    required List<Color> colors,
    required double value,
    required double max,
    required ValueChanged<double> onChanged,
    bool checkerboard = false,
  }) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 22,
          right: 22,
          height: 7,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: CustomPaint(
              painter: checkerboard ? const _ColorCheckerboard() : null,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: colors),
                ),
              ),
            ),
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: Colors.transparent,
            inactiveTrackColor: Colors.transparent,
            thumbColor: Colors.white,
            overlayColor: Colors.black12,
            trackHeight: 7,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
          ),
          child: Slider(
            value: value,
            max: max,
            semanticFormatterCallback: (value) => '$label ${value.round()}',
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  Widget _channelsPanel(BuildContext context) {
    final solid = _color.withAlpha(1).toColor();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            SubtitleColorSwatch(color: _color.toColor(), size: 46, radius: 23),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                children: [
                  _slider(
                    label: 'HSV',
                    colors: [
                      for (var hue = 0.0; hue <= 360; hue += 60)
                        HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
                    ],
                    value: _color.hue,
                    max: 360,
                    onChanged: (value) => _setColor(_color.withHue(value)),
                  ),
                  _slider(
                    label: 'A',
                    colors: [solid.withAlpha(0), solid],
                    value: _color.alpha,
                    max: 1,
                    checkerboard: true,
                    onChanged: (value) => _setColor(_color.withAlpha(value)),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('RGB'),
            const SizedBox(width: 12),
            for (var index = 0; index < 4; index++) ...[
              if (index > 0) const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _channels[index],
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(3),
                  ],
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: 'RGBA'[index],
                    suffixText: index == 3 ? '%' : null,
                  ),
                  onChanged: (value) => _setChannel(index, value),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 630,
      // AlertDialog measures its content before layout. Give the responsive
      // picker a finite box so it is never asked for intrinsic dimensions.
      height: MediaQuery.sizeOf(context).width < 660 ? 455 : 300,
      child: LayoutBuilder(builder: (context, constraints) {
        final surface = _saturationValuePicker();
        final channels = _channelsPanel(context);
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (constraints.maxWidth < 520)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [surface, const SizedBox(height: 16), channels],
                )
              else
                Row(
                  children: [
                    Expanded(child: surface),
                    const SizedBox(width: 24),
                    Expanded(child: channels),
                  ],
                ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.onCancel,
                    child: Text(translate('Cancel')),
                  ),
                  TextButton(
                    onPressed: () => widget.onConfirm(_color.toColor()),
                    child: Text(translate('OK')),
                  ),
                ],
              ),
            ],
          ),
        );
      }),
    );
  }
}

class _ColorCheckerboard extends CustomPainter {
  const _ColorCheckerboard();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final gray = Paint()..color = const Color(0xffcccccc);
    const tileSize = 4.0;
    for (var row = 0; row * tileSize < size.height; row++) {
      for (var col = row % 2; col * tileSize < size.width; col += 2) {
        canvas.drawRect(
            Rect.fromLTWH(col * tileSize, row * tileSize, tileSize, tileSize),
            gray);
      }
    }
  }

  @override
  bool shouldRepaint(_ColorCheckerboard oldDelegate) => false;
}
