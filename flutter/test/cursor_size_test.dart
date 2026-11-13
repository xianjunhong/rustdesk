import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/remote_page.dart';
import 'package:flutter_hbb/generated_bridge.dart' show RustdeskImpl;
import 'package:flutter_hbb/models/input_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/native/custom_cursor.dart';
import 'package:flutter_hbb/utils/image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

class _Binding extends Fake implements RustdeskImpl {
  _Binding({this.controller = false});
  final bool controller;
  final sentInput = <Symbol>[];

  @override
  bool isIncomingOnly({dynamic hint}) => false;
  @override
  bool isOutgoingOnly({dynamic hint}) => controller;
  @override
  String mainGetLocalOption({required String key, dynamic hint}) => '';
  @override
  int versionToNumber({required String v, dynamic hint}) =>
      v.split('.').fold(0, (n, part) => n * 1000 + int.parse(part));

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (const {
      #sessionSendMouse,
      #sessionSendPointer,
      #sessionHandleFlutterKeyEvent,
      #sessionHandleFlutterRawKeyEvent,
      #sessionInputKey,
    }.contains(invocation.memberName)) {
      sentInput.add(invocation.memberName);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Canvas extends ChangeNotifier implements CanvasModel {
  _Canvas(String style)
      : viewStyle = ViewStyle(
            style: style,
            width: 200,
            height: 160,
            displayWidth: 400,
            displayHeight: 320);
  @override
  final ViewStyle viewStyle;
  @override
  final devicePixelRatio = 1.0;
  @override
  double scale = 0.25;
  @override
  final imageOverflow = false.obs;
  @override
  bool get cursorEmbedded => false;
  @override
  Size get size => const Size(200, 160);
  @override
  double get x => 0;
  @override
  double get y => 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Image extends ChangeNotifier implements ImageModel {
  @override
  bool get useTextureRender => false;
  @override
  ui.Image? get image => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Input extends Fake implements InputModel {
  @override
  final relativeMouseMode = false.obs;
}

class _Display extends Display {
  @override
  double scale = 1.0;
}

class _Peer extends Fake implements FfiModel {
  @override
  final pi = PeerInfo();
  @override
  bool get isPeerLinux => pi.platform == kPeerPlatformLinux;
  @override
  bool get isPeerWindows => pi.platform == kPeerPlatformWindows;
}

class _FFI extends Fake implements FFI {
  _FFI(this.canvasModel, {bool realSession = false}) {
    ffiModel = realSession ? FfiModel(WeakReference(this)) : _Peer();
    inputModel = realSession ? InputModel(WeakReference(this)) : _Input();
  }
  @override
  final CanvasModel canvasModel;
  @override
  late final FfiModel ffiModel;
  @override
  late final InputModel inputModel;
  @override
  final sessionId = const Uuid().v4obj();
  @override
  ConnType get connType => ConnType.defaultConn;
  @override
  bool get closed => false;
  @override
  var id = '';
}

class _Cursor extends CursorModel {
  _Cursor(this.cache, FFI ffi) : super(WeakReference(ffi));
  @override
  final CursorData cache;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final channel = Platform.isWindows
      ? SystemChannels.mouseCursor
      : const MethodChannel('flutter_custom_cursor');
  final registrations = <Map<dynamic, dynamic>>[];
  setUp(() {
    platformFFI.setBindingForTesting(_Binding());
    registrations.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      if (!call.method.startsWith('createCustomCursor')) return null;
      final args = call.arguments as Map<dynamic, dynamic>;
      registrations.add(args);
      return args['name'];
    });
  });
  tearDown(() =>
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  testWidgets('A browsing shows a local arrow without forwarding input',
      (tester) async {
    final core = _Binding(controller: true);
    platformFFI.setBindingForTesting(core);
    final canvas = _Canvas(kRemoteViewStyleAdaptive);
    final ffi = _FFI(canvas, realSession: true)..id = 'browse';
    ffi.ffiModel.pi
      ..version = '1.4.6'
      ..platform = kPeerPlatformWindows;
    ffi.ffiModel.setViewOnly(ffi.id, true);
    final overImage = true.obs;
    addTearDown(canvas.dispose);
    addTearDown(ffi.ffiModel.dispose);
    addTearDown(ffi.inputModel.disposeRelativeMouseMode);

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<ImageModel>(create: (_) => _Image()),
          ChangeNotifierProvider<CanvasModel>.value(value: canvas),
          ChangeNotifierProvider<FfiModel>.value(value: ffi.ffiModel),
        ],
        child: ImagePaint(
          ffi: ffi,
          id: ffi.id,
          zoomCursor: false.obs,
          cursorOverImage: overImage,
          keyboardEnabled: true.obs,
          remoteCursorMoved: true.obs,
        ),
      ),
    ));
    MouseCursor cursor() => tester
        .widget<MouseRegion>(find.descendant(
            of: find.byType(ImagePaint), matching: find.byType(MouseRegion)))
        .cursor;
    expect(cursor(), SystemMouseCursors.basic);

    final input = ffi.inputModel;
    input.onPointHoverImage(const PointerHoverEvent(
        kind: ui.PointerDeviceKind.mouse, position: Offset(20, 20)));
    input.onPointDownImage(const PointerDownEvent(
        kind: ui.PointerDeviceKind.mouse,
        position: Offset(20, 20),
        buttons: kPrimaryMouseButton));
    input.onPointMoveImage(const PointerMoveEvent(
        kind: ui.PointerDeviceKind.mouse, position: Offset(30, 30)));
    input.onPointUpImage(const PointerUpEvent(
        kind: ui.PointerDeviceKind.mouse, position: Offset(30, 30)));
    input.onPointerSignalImage(const PointerScrollEvent(
        kind: ui.PointerDeviceKind.mouse, scrollDelta: Offset(0, 10)));
    for (final event in [
      const KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration(seconds: 1)),
      const KeyUpEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: LogicalKeyboardKey.keyA,
          timeStamp: Duration(seconds: 2)),
    ]) {
      expect(input.handleKeyEvent(event), KeyEventResult.handled);
    }
    expect(core.sentInput, isEmpty);
    expect(ffi.ffiModel.showMyCursor, isFalse);

    ffi.ffiModel.setViewOnly(ffi.id, false);
    await tester.pump();
    expect(cursor(), SystemMouseCursors.none);
    ffi.ffiModel.setViewOnly(ffi.id, true);
    await tester.pump();
    expect(cursor(), SystemMouseCursors.basic);
    overImage.value = false;
    await tester.pump();
    expect(cursor(), MouseCursor.defer);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
  for (final scenario in [
    ((4, 64), 0.5, (2, 32)),
    ((8, 8), 0.5, (12, 12)),
  ]) {
    test('native cursor size $scenario',
        () => _checkSize(scenario, registrations));
  }
  test('cursor resize limits preserve the last valid raster', () async {
    for (final size in [(30, 20), (20, 30)]) {
      await _checkResizeLimits(size, registrations);
      registrations.clear();
    }
  });
  for (final pattern in [
    ([128, 0, 0, 128], 128),
    ([255, 0, 0, 255, 0, 0, 0, 0], 127),
  ]) {
    test('Windows peer cursor alpha survives resizing $pattern',
        () => _checkWindowsPeerAlpha(pattern, registrations));
  }
  for (final (style, zoom) in [
    (kRemoteViewStyleOriginal, false),
    (kRemoteViewStyleAdaptive, false),
    (kRemoteViewStyleAdaptive, true),
    (kRemoteViewStyleCustom, false),
    (kRemoteViewStyleCustom, true),
  ]) {
    testWidgets('$style zoom=$zoom follows the live DPR and peer scale',
        (tester) => _checkView(tester, (style, zoom), registrations));
  }
}

CursorData _data((int, int) size, {Offset hotspot = Offset.zero}) {
  final image = img.Image(width: size.$1, height: size.$2, numChannels: 4);
  for (final pixel in image) {
    pixel.setRgba(64, 32, 16, 255);
  }
  image.getPixel(0, 0).setRgba(255, 0, 0, 128);
  return CursorData(
      peerId: 'size',
      id: '$size',
      image: image,
      scale: 1,
      data: Platform.isWindows
          ? image.getBytes(order: img.ChannelOrder.bgra)
          : Uint8List.fromList(img.encodePng(image)),
      hotxOrigin: hotspot.dx,
      hotyOrigin: hotspot.dy,
      width: size.$1,
      height: size.$2);
}

Future<void> _dispose(CursorModel cursor) async {
  for (final key in cursor.cachedKeys) {
    await deleteCustomCursor(key);
  }
  cursor.dispose();
}

Future<void> _checkWindowsPeerAlpha(
    (List<int>, int) pattern, List<Map<dynamic, dynamic>> registrations) async {
  const sourceSize = 64;
  const dpr = 2.0;
  const channels = 4;
  final ffi = _FFI(_Canvas(kRemoteViewStyleAdaptive));
  ffi.ffiModel.pi.platform = kPeerPlatformWindows;
  final cursor = CursorModel(WeakReference<FFI>(ffi))..id = 'alpha';
  addTearDown(() => _dispose(cursor));
  addTearDown(cursor.disposeImages);
  addTearDown(ffi.canvasModel.dispose);
  await cursor.updateCursorData(
      'alpha',
      0,
      0,
      sourceSize,
      sourceSize,
      Uint8List.fromList(List.generate(sourceSize * sourceSize * channels,
          (i) => pattern.$1[i % pattern.$1.length])));
  buildCursorOfCache(cursor, 1.0 / dpr, cursor.cache);
  await Future<void>.delayed(Duration.zero);
  final args = registrations.single;
  final targetSize = (sourceSize / dpr).ceil();
  _expectSize(args, (targetSize, targetSize));
  final bytes = args['buffer'] as Uint8List;
  if (Platform.isWindows) {
    expect(bytes.sublist(0, channels), [0, 0, pattern.$2, pattern.$2]);
  } else {
    final pixel = img.decodePng(bytes)!.getPixel(0, 0);
    expect([pixel.r, pixel.g, pixel.b, pixel.a], [255, 0, 0, pattern.$2]);
  }
}

Future<void> _checkSize(((int, int), double, (int, int)) scenario,
    List<Map<dynamic, dynamic>> registrations) async {
  final ffi = _FFI(_Canvas(kRemoteViewStyleAdaptive));
  final cursor = _Cursor(_data(scenario.$1), ffi);
  addTearDown(() => _dispose(cursor));
  addTearDown(ffi.canvasModel.dispose);
  buildCursorOfCache(cursor, scenario.$2, cursor.cache);
  await Future<void>.delayed(Duration.zero);
  final (width, height) = scenario.$3;
  expect(
      (cursor.cache.rasterWidth, cursor.cache.rasterHeight), (width, height));
  final args = registrations.single;
  final padded = Platform.isLinux && width != height;
  final side = width > height ? width : height;
  _expectSize(args, (padded ? side : width, padded ? side : height));
  if (padded) {
    final bitmap = img.decodePng(args['buffer'] as Uint8List)!;
    final artwork =
        img.copyCrop(bitmap, x: 0, y: 0, width: width, height: height);
    expect(artwork.getBytes(), img.decodePng(cursor.cache.data!)!.getBytes());
    expect(bitmap.where((p) => p.x >= width || p.y >= height).map((p) => p.a),
        everyElement(0));
  }
}

void _expectSize(Map<dynamic, dynamic> args, (int, int) expected) {
  expect((args['width'], args['height']), expected);
  final bytes = args['buffer'] as Uint8List;
  if (Platform.isWindows) {
    const channels = 4;
    expect(bytes.length, expected.$1 * expected.$2 * channels);
  } else {
    final bitmap = img.decodePng(bytes)!;
    expect((bitmap.width, bitmap.height), expected);
  }
}

Future<void> _checkResizeLimits(
    (int, int) size, List<Map<dynamic, dynamic>> registrations) async {
  const maxSide = 512;
  const sourceLongEdge = 30;
  const validScale = maxSide / sourceLongEdge;
  final ffi = _FFI(_Canvas(kRemoteViewStyleAdaptive));
  const hotspot = Offset(4, 7);
  final cursor = _Cursor(_data(size, hotspot: hotspot), ffi);
  addTearDown(() => _dispose(cursor));
  addTearDown(ffi.canvasModel.dispose);
  buildCursorOfCache(cursor, validScale, cursor.cache);
  await Future<void>.delayed(Duration.zero);
  final raster = ((size.$1 * validScale).ceil(), (size.$2 * validScale).ceil());
  final expectedHotspot =
      (hotspot.dx * raster.$1 / size.$1, hotspot.dy * raster.$2 / size.$2);
  _expectSize(
      registrations.single, Platform.isLinux ? (maxSide, maxSide) : raster);
  expect((registrations.single['hotX'], registrations.single['hotY']),
      expectedHotspot);
  // Fail on a small allocation before reaching unsafe sizes without the guard.
  for (final scale in [
    (maxSide + 1) / sourceLongEdge,
    double.maxFinite,
    double.infinity,
    double.nan,
    0.0,
    -1.0,
  ]) {
    buildCursorOfCache(cursor, scale, cursor.cache);
    await Future<void>.delayed(Duration.zero);
    expect(cursor.cache.scale, validScale);
    expect((cursor.cache.rasterWidth, cursor.cache.rasterHeight), raster);
    expect((cursor.cache.hotx, cursor.cache.hoty), expectedHotspot);
  }
  buildCursorOfCache(cursor, 1.0, cursor.cache);
  await Future<void>.delayed(Duration.zero);
  expect(cursor.cache.scale, 1.0);
  _expectSize(registrations.last,
      Platform.isLinux ? (sourceLongEdge, sourceLongEdge) : size);
}

const _viewCases = [
  (1.0, kPeerPlatformMacOS, 2.0),
  (1.25, kPeerPlatformLinux, 2.0),
  (2.0, kPeerPlatformMacOS, 1.0),
];

Future<void> _checkView(WidgetTester tester, (String, bool) mode,
    List<Map<dynamic, dynamic>> registrations) async {
  const sourceSize = 64, customScale = 4.0;
  final canvas = _Canvas(mode.$1);
  final ffi = _FFI(canvas);
  final display = _Display();
  ffi.ffiModel.pi.displays.addAll([Display(), display]);
  ffi.ffiModel.pi.currentDisplay = 1;
  final cursor = _Cursor(_data((sourceSize, sourceSize)), ffi);
  addTearDown(() => _dispose(cursor));
  addTearDown(canvas.dispose);
  addTearDown(tester.view.resetDevicePixelRatio);
  for (final (dpr, peer, peerScale) in _viewCases) {
    ffi.ffiModel.pi.platform = peer;
    display.scale = peerScale;
    canvas.scale = mode.$1 == kRemoteViewStyleCustom
        ? customScale / dpr
        : mode.$1 == kRemoteViewStyleOriginal
            ? 1.0 / dpr
            : canvas.viewStyle.scale;
    tester.view.devicePixelRatio = dpr;
    await tester.pumpWidget(MediaQuery(
      data: MediaQueryData(devicePixelRatio: dpr),
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<ImageModel>(create: (_) => _Image()),
          ChangeNotifierProvider<CanvasModel>.value(value: canvas),
          ChangeNotifierProvider<CursorModel>.value(value: cursor),
        ],
        child: ImagePaint(
          ffi: ffi,
          id: 'size',
          zoomCursor: mode.$2.obs,
          cursorOverImage: true.obs,
          keyboardEnabled: true.obs,
          remoteCursorMoved: false.obs,
        ),
      ),
    ));
    final video = tester.widget<CustomPaint>(find.byType(CustomPaint)).painter
        as ImagePainter;
    final scale = video.scale * (mode.$2 ? 1.0 : 1.0 / (canvas.scale * dpr));
    final size = sourceSize * (peer == kPeerPlatformMacOS ? peerScale : 1.0);
    final w = peer == kPeerPlatformMacOS &&
            !mode.$2 &&
            mode.$1 != kRemoteViewStyleOriginal
        ? (sourceSize * (Platform.isWindows ? dpr : 1.0)).ceil()
        : (size * scale * (Platform.isWindows ? dpr : 1.0)).ceil();
    final key = cursor.nativeKey(cursor.cache, cursor.cache.scale);
    _expectSize(registrations.singleWhere((v) => v['name'] == key), (w, w));
  }
  await tester.pumpWidget(const SizedBox.shrink());
}
