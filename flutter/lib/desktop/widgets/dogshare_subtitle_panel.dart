import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/dogshare_subtitle_frame.dart';
import 'package:get/get.dart';

import 'dogshare_subtitle_color_picker.dart';

const dogShareSubtitleDialogTag = 'dogshare-subtitle-editor';

class _SubtitlePageControls extends StatelessWidget {
  const _SubtitlePageControls({required this.draft});

  final DogShareSubtitleDraft draft;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: translate('Previous subtitle page'),
            icon: const Icon(Icons.chevron_left),
            onPressed:
                draft.page > 0 ? () => draft.selectPage(draft.page - 1) : null,
          ),
          Text('${draft.page + 1} / ${draft.pageCount}'),
          IconButton(
            tooltip: translate('Next subtitle page'),
            icon: const Icon(Icons.chevron_right),
            onPressed: draft.page + 1 < draft.pageCount
                ? () => draft.selectPage(draft.page + 1)
                : null,
          ),
        ],
      );
}

class DogShareSubtitleChatControls extends StatelessWidget {
  const DogShareSubtitleChatControls(
      {super.key, required this.ffi, required this.draft});

  final FFI ffi;
  final DogShareSubtitleDraft draft;

  @override
  Widget build(BuildContext context) {
    final showLabel = translate('Show subtitles');
    return Obx(() {
      final ready = ffi.ffiModel.pi.isSet.isTrue &&
          ffi.ffiModel.waitForFirstImage.isFalse;
      return ListenableBuilder(
        listenable: draft,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text(showLabel)),
                  Semantics(
                    label: showLabel,
                    child: Switch(
                      value: draft.enabled,
                      onChanged: ready ? draft.setDisplayEnabled : null,
                    ),
                  ),
                ],
              ),
              TextButton.icon(
                icon: const Icon(Icons.tune, size: 18),
                label: Text(translate('Subtitle settings')),
                onPressed: ready ? _showSettings : null,
              ),
              if (ready && draft.enabled && draft.pageCount > 1)
                _SubtitlePageControls(draft: draft),
            ],
          ),
        ),
      );
    });
  }

  void _showSettings() {
    if (ffi.dialogManager.existing(dogShareSubtitleDialogTag)) return;
    ffi.dialogManager.show<void>(
      (_, close, context) => CustomAlertDialog(
        title: Text(translate('Subtitle settings')),
        content: _SubtitleSettings(ffi: ffi, draft: draft),
        actions: [
          TextButton(onPressed: close, child: Text(translate('Close'))),
        ],
        onCancel: close,
      ),
      tag: dogShareSubtitleDialogTag,
    );
  }
}

class _SubtitleSettings extends StatefulWidget {
  const _SubtitleSettings({required this.ffi, required this.draft});

  final FFI ffi;
  final DogShareSubtitleDraft draft;

  @override
  State<_SubtitleSettings> createState() => _SubtitleSettingsState();
}

class _SubtitleSettingsState extends State<_SubtitleSettings> {
  DogShareSubtitleDraft get _draft => widget.draft;

  Widget _sizeSlider(String label, int value, int min, int max,
          ValueChanged<double> onChanged) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${translate(label)}: $value px'),
          Slider(
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: (max - min) ~/ 20,
            value: value.toDouble(),
            label: '$value px',
            onChanged: onChanged,
          ),
        ],
      );

  Future<void> _chooseColor() async {
    final selected = await widget.ffi.dialogManager.show<Color>(
      (_, close, context) => CustomAlertDialog(
        title: Text(translate('Choose color')),
        contentBoxConstraints: const BoxConstraints(maxWidth: 650),
        content: DogShareSubtitleColorPicker(
          initialColor: Color(_draft.color),
          onConfirm: close,
          onCancel: close,
        ),
        onCancel: close,
      ),
    );
    if (mounted && selected != null) {
      _draft.color = selected.value;
      _draft.styleChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: ListenableBuilder(
        listenable: _draft,
        builder: (context, _) {
          final opacity = Color(_draft.color).alpha / 255;
          final opacityLabel = '${(opacity * 100).round()}%';
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Receiver subtitle area')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Fit subtitles automatically')),
                value: _draft.autoFit,
                onChanged: _draft.setAutoFit,
              ),
              if (!_draft.autoFit) ...[
                _sizeSlider(
                  'Subtitle width',
                  _draft.width,
                  DogShareSubtitleFrame.minWidth,
                  DogShareSubtitleFrame.maxWidth,
                  (value) => _draft.setSize(width: value.round()),
                ),
                _sizeSlider(
                  'Subtitle height',
                  _draft.height,
                  DogShareSubtitleFrame.minHeight,
                  DogShareSubtitleFrame.maxHeight,
                  (value) => _draft.setSize(height: value.round()),
                ),
              ],
              Text('${translate('Font size')}: ${_draft.fontSize.round()} px'),
              Slider(
                min: 8,
                max: 96,
                divisions: 88,
                value: _draft.fontSize,
                onChanged: (value) {
                  _draft.fontSize = value;
                  _draft.styleChanged();
                },
              ),
              Text(translate('Font family')),
              DropdownButton<String>(
                value: _draft.fontFamily,
                isExpanded: true,
                items: [
                  for (final font in DogShareSubtitleFrame.fontFamilies)
                    DropdownMenuItem(
                      value: font,
                      child: Text(font, style: TextStyle(fontFamily: font)),
                    ),
                ],
                onChanged: (font) {
                  if (font == null) return;
                  _draft.fontFamily = font;
                  _draft.styleChanged();
                },
              ),
              TextButton.icon(
                icon: SubtitleColorSwatch(color: Color(_draft.color)),
                label: Text(translate('Text color')),
                onPressed: _chooseColor,
              ),
              Text('${translate('Window opacity')}: $opacityLabel'),
              Slider(
                value: opacity,
                divisions: 100,
                label: opacityLabel,
                onChanged: (value) {
                  _draft.color = Color(_draft.color)
                      .withAlpha((value * 255).round())
                      .value;
                  _draft.styleChanged();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(translate('Send in real time')),
                value: _draft.realtime,
                onChanged: _draft.setRealtime,
              ),
            ],
          );
        },
      ),
    );
  }
}
