import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/chat_model.dart';

class DogShareChatComposer extends StatelessWidget {
  const DogShareChatComposer({super.key, required this.chatModel});

  final ChatModel chatModel;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Stack(
                children: [
                  TextField(
                    controller: chatModel.textController,
                    focusNode: chatModel.inputNode,
                    minLines: 4,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    textAlignVertical: TextAlignVertical.top,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.4,
                      color: Theme.of(context).textTheme.titleLarge?.color,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Enter 发送，Shift + Enter 换行',
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surface,
                      contentPadding: const EdgeInsets.fromLTRB(12, 14, 40, 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: chatModel.textController,
                      builder: (context, input, _) => IconButton(
                        tooltip: translate('Clear'),
                        icon: const Icon(Icons.clear, size: 18),
                        constraints: const BoxConstraints.tightFor(
                            width: 32, height: 32),
                        padding: EdgeInsets.zero,
                        onPressed:
                            input.text.isEmpty ? null : chatModel.clearDraft,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: chatModel.textController,
              builder: (context, input, _) => IconButton(
                tooltip: translate('Send'),
                icon: const Icon(Icons.send),
                color: MyTheme.accent,
                constraints:
                    const BoxConstraints.tightFor(width: 40, height: 40),
                padding: EdgeInsets.zero,
                onPressed: input.text.trim().isEmpty ||
                        (input.isComposingRangeValid &&
                            !input.composing.isCollapsed)
                    ? null
                    : chatModel.sendDraft,
              ),
            ),
          ],
        ),
      );
}
