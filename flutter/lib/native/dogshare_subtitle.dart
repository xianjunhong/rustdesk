import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as path;

final _sendPage = DynamicLibrary.open(
        path.join(path.dirname(Platform.resolvedExecutable), 'librustdesk.dll'))
    .lookupFunction<Void Function(Int32, Uint32, Uint32, Uint32),
        void Function(int, int, int, int)>('dogshare_subtitle_page');

void sendPage(int connId, int revision, int page, int count) =>
    _sendPage(connId, revision, page, count);
