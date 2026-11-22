import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/network/components/advanced_filter.dart';
import 'package:proxypin/network/components/host_filter.dart';

FilterSet set(List<FilterRule> rules, {bool enabled = true}) => FilterSet(name: 't', enabled: enabled, rules: rules);

FilterRule rule(FilterRuleType t, String v, FilterAction a) => FilterRule(type: t, value: v, action: a);

bool? decide(String host, {int port = 443, bool secure = true, bool? ws}) =>
    AdvancedFilter.decide(FilterTarget(host, port: port, secure: secure, websocket: ws));

void main() {
  setUp(() {
    AdvancedFilter.enabled = true;
    AdvancedFilter.sets.clear();
  });

  test('disabled = no opinion', () {
    AdvancedFilter.sets.add(set([rule(FilterRuleType.domain, 'a.com', FilterAction.exclude)]));
    AdvancedFilter.enabled = false;
    expect(decide('a.com'), isNull);
  });

  test('domain include / exclude / wildcard', () {
    AdvancedFilter.sets.add(set([rule(FilterRuleType.domain, 'almanasa.tv', FilterAction.include)]));
    expect(decide('almanasa.tv'), isFalse);
    expect(decide('tv.almanasa.tv'), isFalse);
    expect(decide('google.com'), isTrue);
    expect(decide('notalmanasa.tv'), isTrue);

    AdvancedFilter.sets
      ..clear()
      ..add(set([rule(FilterRuleType.domain, '*.cdn.example.com, ads.*', FilterAction.exclude)]));
    expect(decide('x.cdn.example.com'), isTrue);
    expect(decide('ads.google.com'), isTrue);
    expect(decide('cdn.example.com'), isNull);
  });

  test('exception beats exclude and the host blacklist', () {
    AdvancedFilter.sets.add(set([
      rule(FilterRuleType.port, '443', FilterAction.exclude),
      rule(FilterRuleType.domain, 'api.example.com', FilterAction.always),
    ]));
    expect(decide('api.example.com'), isFalse);
    expect(decide('other.com'), isTrue);
    // default blacklist has *.apple.com
    AdvancedFilter.sets.add(set([rule(FilterRuleType.domain, 'www.apple.com', FilterAction.always)]));
    expect(HostFilter.filter('www.apple.com', port: 443, secure: true), isFalse);
  });

  test('ip single / cidr / range / v6 and domains never match ip rules', () {
    AdvancedFilter.sets.add(set([
      rule(FilterRuleType.ip, '10.0.0.0/8, 1.1.1.1-1.1.1.9, 8.8.8.8, 2001:db8::/32', FilterAction.exclude)
    ]));
    expect(decide('10.20.30.40'), isTrue);
    expect(decide('11.0.0.1'), isNull);
    expect(decide('1.1.1.5'), isTrue);
    expect(decide('1.1.1.10'), isNull);
    expect(decide('8.8.8.8'), isTrue);
    expect(decide('2001:db8::1'), isTrue);
    expect(decide('2001:db9::1'), isNull);
    expect(decide('example.com'), isNull);
  });

  test('ports', () {
    AdvancedFilter.sets.add(set([rule(FilterRuleType.port, '80, 8000-9000', FilterAction.exclude)]));
    expect(decide('a.com', port: 80), isTrue);
    expect(decide('a.com', port: 8443), isTrue);
    expect(decide('a.com', port: 443), isNull);
  });

  test('protocols incl. websocket unknown at connection level', () {
    AdvancedFilter.sets.add(set([rule(FilterRuleType.protocol, 'https', FilterAction.include)]));
    expect(decide('a.com', secure: true), isFalse);
    expect(decide('a.com', port: 80, secure: false), isTrue);

    AdvancedFilter.sets
      ..clear()
      ..add(set([rule(FilterRuleType.protocol, 'ws', FilterAction.include)]));
    expect(decide('a.com', ws: null), isFalse, reason: 'unknown yet: keep capturing');
    expect(decide('a.com', ws: false), isTrue);
    expect(decide('a.com', ws: true), isFalse);
  });

  test('disabled sets and rules are ignored; json round trip', () {
    AdvancedFilter.sets.add(set([rule(FilterRuleType.domain, 'a.com', FilterAction.exclude)], enabled: false));
    final r = rule(FilterRuleType.domain, 'b.com', FilterAction.exclude)..enabled = false;
    AdvancedFilter.sets.add(set([r]));
    expect(decide('a.com'), isNull);
    expect(decide('b.com'), isNull);

    final json = AdvancedFilter.toJson();
    AdvancedFilter.load(json);
    expect(AdvancedFilter.sets.length, 2);
    expect(AdvancedFilter.sets.first.enabled, isFalse);
    expect(AdvancedFilter.sets.last.rules.first.enabled, isFalse);
    expect(AdvancedFilter.enabled, isTrue);
  });
}
