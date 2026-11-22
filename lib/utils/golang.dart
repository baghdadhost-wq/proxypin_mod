/*
 * proxypin_mod: copy a request as Go (net/http) code.
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'package:proxypin/network/http/http.dart';

String copyAsGo(HttpRequest request) {
  final hasBody = request.body?.isNotEmpty ?? false;
  final sb = StringBuffer();
  sb.writeln('package main\n');
  sb.writeln('import (');
  sb.writeln('\t"fmt"');
  sb.writeln('\t"io"');
  sb.writeln('\t"net/http"');
  if (hasBody) sb.writeln('\t"strings"');
  sb.writeln(')\n');
  sb.writeln('func main() {');
  if (hasBody) {
    sb.writeln('\tbody := strings.NewReader(${_goStr(request.bodyAsString)})');
  }
  sb.writeln('\treq, err := http.NewRequest(${_goStr(request.method.name)}, ${_goStr(request.requestUrl)}, '
      '${hasBody ? 'body' : 'nil'})');
  sb.writeln('\tif err != nil {\n\t\tpanic(err)\n\t}');
  request.headers.forEach((name, values) {
    final lower = name.toLowerCase();
    if (lower == 'content-length' || lower == 'host' || lower == 'accept-encoding') return;
    for (final v in values) {
      sb.writeln('\treq.Header.Add(${_goStr(name)}, ${_goStr(v)})');
    }
  });
  sb.writeln('\n\tresp, err := http.DefaultClient.Do(req)');
  sb.writeln('\tif err != nil {\n\t\tpanic(err)\n\t}');
  sb.writeln('\tdefer resp.Body.Close()');
  sb.writeln('\tdata, _ := io.ReadAll(resp.Body)');
  sb.writeln('\tfmt.Println(resp.Status)');
  sb.writeln('\tfmt.Println(string(data))');
  sb.writeln('}');
  return sb.toString();
}

/// Go string literal: raw `...` when possible, quoted otherwise.
String _goStr(String s) {
  if (!s.contains('`') && !s.contains('\r')) return '`$s`';
  final b = StringBuffer('"');
  for (final r in s.runes) {
    switch (r) {
      case 0x22:
        b.write(r'\"');
        break;
      case 0x5c:
        b.write(r'\\');
        break;
      case 0x0a:
        b.write(r'\n');
        break;
      case 0x0d:
        b.write(r'\r');
        break;
      case 0x09:
        b.write(r'\t');
        break;
      default:
        b.writeCharCode(r);
    }
  }
  b.write('"');
  return b.toString();
}
