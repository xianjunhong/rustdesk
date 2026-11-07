Future<String> refresh() async => snapshot();
String snapshot() =>
    '{"authorized":false,"expires_at":0,"error":"Unsupported platform"}';
bool overlayAllowed() => false;
void invalidate() {}
