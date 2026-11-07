import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

final _library = DynamicLibrary.open(
    path.join(path.dirname(Platform.resolvedExecutable), 'librustdesk.dll'));

String _read(String name) {
  final call = _library
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(name);
  final free = _library.lookupFunction<Void Function(Pointer<Utf8>),
      void Function(Pointer<Utf8>)>('tomdesk_account_free');
  final pointer = call();
  if (pointer == nullptr) throw StateError('Account state is unavailable');
  try {
    return pointer.toDartString();
  } finally {
    free(pointer);
  }
}

Future<String> refresh() => Isolate.run(() => _read('tomdesk_account_refresh'));
String snapshot() => _read('tomdesk_account_snapshot');
bool overlayAllowed() =>
    _library.lookupFunction<Bool Function(), bool Function()>(
        'tomdesk_account_overlay_allowed')();
void invalidate() => _library.lookupFunction<Void Function(), void Function()>(
    'tomdesk_account_invalidate')();
