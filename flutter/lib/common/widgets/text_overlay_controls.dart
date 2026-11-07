import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/text_overlay_model.dart';

class TextOverlayControls extends StatelessWidget {
  final String source;
  final String label;
  final bool available;

  const TextOverlayControls({
    super.key,
    required this.source,
    required this.label,
    required this.available,
  });

  @override
  Widget build(BuildContext context) {
    final model = TextOverlayModel.instance;
    return AnimatedBuilder(
      animation: model,
      builder: (context, _) {
        final enabled = model.enabledFor(source);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(translate('Show incoming chat as subtitles')),
                    value: enabled,
                    onChanged: available || enabled
                        ? (value) {
                            if (value) {
                              model.enable(
                                source: source,
                                label: label,
                                placeholder:
                                    translate('Waiting for incoming messages'),
                              );
                            } else {
                              model.disable(source);
                            }
                          }
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: translate('Subtitle settings'),
                  icon: const Icon(Icons.tune, size: 20),
                  onPressed: () => _showSettings(context, model),
                ),
              ]),
              Text(
                translate(
                    'Local display only. Send normal chat messages; the receiver chooses whether to show subtitles.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (model.error != null)
                Text(
                  translate(model.error!),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showSettings(BuildContext context, TextOverlayModel model) {
    showDialog<void>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: model,
        builder: (context, _) => AlertDialog(
          title: Text(translate('Subtitle settings')),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${translate('Subtitle width')}: ${model.width.round()}'),
                  Slider(
                    value: model.width,
                    min: 240,
                    max: 2560,
                    divisions: 116,
                    label: '${model.width.round()}',
                    onChanged: (value) => model.updateStyle(width: value),
                  ),
                  Text('${translate('Subtitle height')}: ${model.height.round()}'),
                  Slider(
                    value: model.height,
                    min: 80,
                    max: 1440,
                    divisions: 68,
                    label: '${model.height.round()}',
                    onChanged: (value) => model.updateStyle(height: value),
                  ),
                  Text('${translate('Font size')}: ${model.fontSize.round()}'),
                  Slider(
                    value: model.fontSize,
                    min: 16,
                    max: 72,
                    divisions: 28,
                    label: '${model.fontSize.round()}',
                    onChanged: (value) => model.updateStyle(fontSize: value),
                  ),
                  Text(translate('Font family')),
                  DropdownButton<String>(
                    isExpanded: true,
                    value: model.fontFamily,
                    items: const ['Microsoft YaHei', 'Segoe UI', 'SimSun']
                        .map((font) => DropdownMenuItem(
                              value: font,
                              child: Text(font),
                            ))
                        .toList(),
                    onChanged: (value) => model.updateStyle(fontFamily: value),
                  ),
                  Text(translate('Text color')),
                  DropdownButton<int>(
                    isExpanded: true,
                    value: model.color,
                    items: const [
                      0xffffd54f,
                      0xffffffff,
                      0xff80deea,
                      0xffa5d6a7,
                      0xffff8a80,
                    ]
                        .map((color) => DropdownMenuItem(
                              value: color,
                              child: Row(children: [
                                Icon(Icons.circle, color: Color(color)),
                                const SizedBox(width: 8),
                                Text(
                                    '#${(color & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}'),
                              ]),
                            ))
                        .toList(),
                    onChanged: (value) => model.updateStyle(color: value),
                  ),
                  Text(
                      '${translate('Window opacity')}: ${(model.opacity * 100).round()}%'),
                  Slider(
                    value: model.opacity,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: '${(model.opacity * 100).round()}%',
                    onChanged: (value) => model.updateStyle(opacity: value),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(translate('Close')),
            ),
          ],
        ),
      ),
    );
  }
}
