import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../desktop/widgets/tomdesk_subtitle_panel.dart';
import '../../mobile/pages/home_page.dart';
import 'text_overlay_controls.dart';
import '../../models/tomdesk_role.dart';

enum ChatPageType {
  mobileMain,
  desktopCM,
}

class ChatPage extends StatelessWidget implements PageShape {
  late final ChatModel chatModel;
  final ChatPageType? type;

  ChatPage({ChatModel? chatModel, this.type}) {
    this.chatModel = chatModel ?? gFFI.chatModel;
  }

  @override
  final title = translate("Chat");

  @override
  final icon = unreadTopRightBuilder(gFFI.chatModel.mobileUnreadSum);

  @override
  final appBarActions = [
    PopupMenuButton<MessageKey>(
        tooltip: "",
        icon: unreadTopRightBuilder(gFFI.chatModel.mobileUnreadSum,
            icon: Icon(Icons.group)),
        itemBuilder: (context) {
          // only mobile need [appBarActions], just bind gFFI.chatModel
          final chatModel = gFFI.chatModel;
          return chatModel.messages.entries.map((entry) {
            final key = entry.key;
            final user = entry.value.chatUser;
            final client = gFFI.serverModel.clients
                .firstWhereOrNull((e) => e.id == key.connId);
            final connected =
                gFFI.serverModel.clients.any((e) => e.id == key.connId);
            return PopupMenuItem<MessageKey>(
              child: Row(
                children: [
                  Icon(
                          key.isOut
                              ? Icons.call_made_rounded
                              : Icons.call_received_rounded,
                          color: MyTheme.accent)
                      .marginOnly(right: 6),
                  Text("${user.firstName}   ${user.id}"),
                  if (connected)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color.fromARGB(255, 46, 205, 139)),
                    ).marginSymmetric(horizontal: 2),
                  if (client != null)
                    unreadMessageCountBuilder(client.unreadChatMessageCount)
                        .marginOnly(left: 4)
                ],
              ),
              value: key,
            );
          }).toList();
        },
        onSelected: (key) {
          gFFI.chatModel.changeCurrentKey(key);
        })
  ];

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: chatModel,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Consumer<ChatModel>(
          builder: (context, chatModel, child) {
            final readOnly = type == ChatPageType.mobileMain &&
                    (chatModel.currentKey.connId == ChatModel.clientModeID ||
                        gFFI.serverModel.clients.every((e) =>
                            e.id != chatModel.currentKey.connId ||
                            chatModel.currentUser == null)) ||
                type == ChatPageType.desktopCM &&
                    gFFI.serverModel.clients
                            .firstWhereOrNull(
                                (e) => e.id == chatModel.currentKey.connId)
                            ?.disconnected ==
                        true;
            final pairedComposer = chatModel.supportsOutgoingSubtitles;
            final chatPage = Stack(
              children: [
                LayoutBuilder(builder: (context, constraints) {
                  final sendButton = defaultSendButton(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                    color: MyTheme.accent,
                    icon: Icons.send_rounded,
                  );
                  final chat = DashChat(
                    onSend: chatModel.send,
                    currentUser: chatModel.me,
                    messages: chatModel
                            .messages[chatModel.currentKey]?.chatMessages ??
                        [],
                    readOnly: readOnly,
                    inputOptions: InputOptions(
                      focusNode: chatModel.inputNode,
                      textController: chatModel.textController,
                      alwaysShowSend: pairedComposer,
                      inputTextStyle: TextStyle(
                          fontSize: pairedComposer ? 15 : 14,
                          color: Theme.of(context).textTheme.titleLarge?.color),
                      inputDecoration: InputDecoration(
                        isDense: true,
                        hintText: translate('Write a message'),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.background,
                        contentPadding: pairedComposer
                            ? const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 14)
                            : const EdgeInsets.all(10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10.0),
                          borderSide: const BorderSide(
                            width: 1,
                            style: BorderStyle.solid,
                          ),
                        ),
                        suffixIcon: pairedComposer
                            ? ValueListenableBuilder<TextEditingValue>(
                                valueListenable: chatModel.textController,
                                builder: (context, input, _) => IconButton(
                                  tooltip: translate('Clear'),
                                  icon: const Icon(Icons.clear, size: 18),
                                  padding: EdgeInsets.zero,
                                  onPressed: input.text.isEmpty
                                      ? null
                                      : chatModel.clearDraft,
                                ),
                              )
                            : null,
                        suffixIconConstraints: pairedComposer
                            ? const BoxConstraints.tightFor(
                                width: 32, height: 36)
                            : null,
                      ),
                      sendButtonBuilder: pairedComposer
                          ? (send) => ValueListenableBuilder<TextEditingValue>(
                                valueListenable: chatModel.textController,
                                builder: (context, input, _) => IconButton(
                                  tooltip: translate('Send'),
                                  icon: const Icon(Icons.send),
                                  color: MyTheme.accent,
                                  onPressed: input.text.trim().isEmpty ||
                                          (input.isComposingRangeValid &&
                                              !input.composing.isCollapsed)
                                      ? null
                                      : send,
                                ),
                              )
                          : sendButton,
                    ),
                    messageOptions: MessageOptions(
                      showOtherUsersAvatar: false,
                      showOtherUsersName: false,
                      textColor: Colors.white,
                      maxWidth: constraints.maxWidth * 0.7,
                      messageTextBuilder: (message, _, __) {
                        final isOwnMessage = message.user.id.isBlank!;
                        return Column(
                          crossAxisAlignment: isOwnMessage
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(message.text,
                                style: TextStyle(color: Colors.white)),
                            Text(
                              "${message.createdAt.hour}:${message.createdAt.minute.toString().padLeft(2, '0')}",
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                              ),
                            ).marginOnly(top: 3),
                          ],
                        );
                      },
                      messageDecorationBuilder:
                          (message, previousMessage, nextMessage) {
                        final isOwnMessage = message.user.id.isBlank!;
                        return defaultMessageDecoration(
                          color:
                              isOwnMessage ? MyTheme.accent : Colors.blueGrey,
                          borderTopLeft: 8,
                          borderTopRight: 8,
                          borderBottomRight: isOwnMessage ? 2 : 8,
                          borderBottomLeft: isOwnMessage ? 8 : 2,
                        );
                      },
                    ),
                  ).workaroundFreezeLinuxMint();
                  return SelectionArea(child: chat);
                }),
              ],
            ).paddingOnly(bottom: 8);
            if (!isWindows) return chatPage;
            final role = tomDeskClientRole;
            final session = chatModel.parent.target;
            if (session != null && chatModel.supportsOutgoingSubtitles) {
              return Column(children: [
                TomDeskSubtitleChatControls(
                    ffi: session, draft: chatModel.subtitleDraft),
                Expanded(child: chatPage),
              ]);
            }
            if (role != null) return chatPage;
            return Column(children: [
              TextOverlayControls(
                source: chatModel.textOverlaySource(chatModel.currentKey),
                label: chatModel.currentKey.peerId,
                available: !readOnly && chatModel.currentKey.peerId.isNotEmpty,
              ),
              Expanded(child: chatPage),
            ]);
          },
        ),
      ),
    );
  }
}
