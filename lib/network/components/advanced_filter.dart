/*
 * proxypin_mod: advanced capture filters.
 *
 * Rules work on what the proxy really knows about a connection:
 *  - domain   : host name, wildcard allowed (*.example.com). "example.com" also matches its subdomains.
 *  - ip       : single IP, CIDR (10.0.0.0/8, 2001:db8::/32) or IPv4 range (1.1.1.1-1.1.1.9).
 *               Matches only when the client connected to a literal IP (the proxy does not resolve DNS).
 *  - port     : 443, 8000-9000, 80,8080
 *  - protocol : http, https, ws (ws/wss are known only after the HTTP upgrade request)
 *
 * Actions, in priority order:
 *  - always  : exception, always capture (beats every other rule and the host black/white list)
 *  - exclude : do not capture / decrypt (traffic is relayed as is)
 *  - include : when any include rule is active, only matching traffic is captured
 *
 * Rules are grouped in named sets that can be switched on and off quickly.
 * Persisted inside config.cnf under "advancedFilter".
 *
 * Licensed under the Apache License, Version 2.0.
 */
import 'dart:io';
import 'dart:typed_data';

enum FilterRuleType {
  domain('النطاق'),
  ip('عنوان IP'),
  port('المنفذ'),
  protocol('البروتوكول');

  final String label;

  const FilterRuleType(this.label);

  static FilterRuleType of(String? name) =>
      FilterRuleType.values.firstWhere((e) => e.name == name, orElse: () => FilterRuleType.domain);
}

enum FilterAction {
  always('استثناء: التقط دائماً'),
  exclude('استبعاد: لا تلتقط'),
  include('حصر: التقط هذا فقط');

  final String label;

  const FilterAction(this.label);

  static FilterAction of(String? name) =>
      FilterAction.values.firstWhere((e) => e.name == name, orElse: () => FilterAction.exclude);
}

class FilterRule {
  FilterRuleType type;
  String value;
  FilterAction action;
  bool enabled;

  FilterRule({required this.type, required this.value, required this.action, this.enabled = true});

  factory FilterRule.fromJson(Map json) => FilterRule(
        type: FilterRuleType.of(json['type']),
        value: '${json['value'] ?? ''}',
        action: FilterAction.of(json['action']),
        enabled: json['enabled'] != false,
      );

  Map<String, dynamic> toJson() => {'type': type.name, 'value': value, 'action': action.name, 'enabled': enabled};

  /// Returns null when the rule cannot decide yet (e.g. "ws" before the upgrade request is seen).
  bool? matches(FilterTarget t) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return false;
    switch (type) {
      case FilterRuleType.domain:
        return v.split(RegExp(r'[,\s]+')).any((p) => p.isNotEmpty && _domain(p, t.host));
      case FilterRuleType.ip:
        final ip = InternetAddress.tryParse(t.host);
        if (ip == null) return false;
        return v.split(RegExp(r'[,\s]+')).any((p) => p.isNotEmpty && _ip(p, ip));
      case FilterRuleType.port:
        if (t.port == null) return false;
        return v.split(RegExp(r'[,\s]+')).any((p) => _port(p, t.port!));
      case FilterRuleType.protocol:
        return _protocol(v, t);
    }
  }

  static bool _domain(String pattern, String host) {
    host = host.toLowerCase();
    if (pattern.contains('*')) {
      final re = RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$');
      return re.hasMatch(host);
    }
    return host == pattern || host.endsWith('.$pattern');
  }

  static bool _port(String p, int port) {
    final dash = p.indexOf('-');
    if (dash > 0) {
      final a = int.tryParse(p.substring(0, dash).trim());
      final b = int.tryParse(p.substring(dash + 1).trim());
      return a != null && b != null && port >= a && port <= b;
    }
    return int.tryParse(p.trim()) == port;
  }

  static bool? _protocol(String v, FilterTarget t) {
    final names = v.split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
    bool? result = false;
    for (final n in names) {
      switch (n) {
        case 'http':
          if (!t.secure && t.websocket != true) return true;
          break;
        case 'https':
          if (t.secure && t.websocket != true) return true;
          break;
        case 'ws':
        case 'websocket':
          if (t.websocket == null) {
            result = null; // unknown at connection level
          } else if (t.websocket!) {
            return true;
          }
          break;
        case 'wss':
          if (t.websocket == null) {
            result = null;
          } else if (t.websocket! && t.secure) {
            return true;
          }
          break;
      }
    }
    return result;
  }

  static bool _ip(String pattern, InternetAddress ip) {
    final dash = pattern.indexOf('-');
    if (dash > 0 && !pattern.contains('/')) {
      final a = InternetAddress.tryParse(pattern.substring(0, dash).trim());
      final b = InternetAddress.tryParse(pattern.substring(dash + 1).trim());
      if (a == null || b == null || a.type != ip.type || b.type != ip.type) return false;
      return _cmp(ip.rawAddress, a.rawAddress) >= 0 && _cmp(ip.rawAddress, b.rawAddress) <= 0;
    }
    final slash = pattern.indexOf('/');
    final base = InternetAddress.tryParse(slash < 0 ? pattern : pattern.substring(0, slash));
    if (base == null || base.type != ip.type) return false;
    final bits = slash < 0 ? base.rawAddress.length * 8 : int.tryParse(pattern.substring(slash + 1)) ?? -1;
    if (bits < 0 || bits > base.rawAddress.length * 8) return false;
    return _prefixEquals(ip.rawAddress, base.rawAddress, bits);
  }

  static int _cmp(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }

  static bool _prefixEquals(Uint8List a, Uint8List b, int bits) {
    var i = 0;
    for (; bits >= 8; bits -= 8, i++) {
      if (a[i] != b[i]) return false;
    }
    if (bits == 0) return true;
    final mask = (0xff << (8 - bits)) & 0xff;
    return (a[i] & mask) == (b[i] & mask);
  }
}

class FilterSet {
  String name;
  bool enabled;
  List<FilterRule> rules;

  FilterSet({required this.name, this.enabled = true, List<FilterRule>? rules}) : rules = rules ?? [];

  factory FilterSet.fromJson(Map json) => FilterSet(
        name: '${json['name'] ?? 'مجموعة'}',
        enabled: json['enabled'] != false,
        rules: (json['rules'] as List? ?? const []).whereType<Map>().map(FilterRule.fromJson).toList(),
      );

  Map<String, dynamic> toJson() => {'name': name, 'enabled': enabled, 'rules': rules.map((e) => e.toJson()).toList()};
}

/// What the proxy knows about a connection / request.
class FilterTarget {
  final String host;
  final int? port;
  final bool secure;

  /// null = not known yet (connection level), true/false once the request headers are seen.
  final bool? websocket;

  const FilterTarget(this.host, {this.port, this.secure = false, this.websocket});
}

class AdvancedFilter {
  static bool enabled = false;
  static final List<FilterSet> sets = [];

  static void load(Map? json) {
    sets.clear();
    if (json == null) return;
    enabled = json['enabled'] == true;
    sets.addAll((json['sets'] as List? ?? const []).whereType<Map>().map(FilterSet.fromJson));
  }

  static Map<String, dynamic> toJson() => {'enabled': enabled, 'sets': sets.map((e) => e.toJson()).toList()};

  static Iterable<FilterRule> get _activeRules =>
      sets.where((s) => s.enabled).expand((s) => s.rules).where((r) => r.enabled && r.value.trim().isNotEmpty);

  /// true = do not capture, false = capture, null = no opinion (fall back to the host black/white list).
  static bool? decide(FilterTarget t) {
    if (!enabled) return null;
    final rules = _activeRules.toList();
    if (rules.isEmpty) return null;

    for (final r in rules.where((r) => r.action == FilterAction.always)) {
      if (r.matches(t) == true) return false;
    }
    for (final r in rules.where((r) => r.action == FilterAction.exclude)) {
      if (r.matches(t) == true) return true;
    }
    final includes = rules.where((r) => r.action == FilterAction.include).toList();
    if (includes.isNotEmpty) {
      var unknown = false;
      for (final r in includes) {
        final m = r.matches(t);
        if (m == true) return false;
        if (m == null) unknown = true;
      }
      // a "ws only" rule cannot be decided before the upgrade request: keep the connection open for now
      return unknown ? false : true;
    }
    return null;
  }
}
