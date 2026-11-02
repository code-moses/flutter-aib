import 'package:aib_core/aib_core.dart';
import 'package:test/test.dart';

RunPoint _point(String label, {double? score, double? tokens, Set<String> nominallyPriced = const {}}) =>
    RunPoint(label: label, episodes: 10, metrics: {'weighted_score': ?score, 'tokens_total': ?tokens}, nominallyPriced: nominallyPriced);

void main() {
  group('paretoFrontier', () {
    test('a run nothing beats on both axes is on it', () {
      final frontier = RunSweep.paretoFrontier([
        _point('cheap', score: 0.4, tokens: 10000),
        _point('good', score: 0.8, tokens: 60000),
        _point('dominated', score: 0.5, tokens: 70000),
      ]);
      expect(frontier, {'cheap', 'good'});
    });

    test('an equal run does not push its twin off', () {
      // Strictly better on one axis is what dominates; identical is not.
      final frontier = RunSweep.paretoFrontier([_point('a', score: 0.5, tokens: 1000), _point('b', score: 0.5, tokens: 1000)]);
      expect(frontier, {'a', 'b'});
    });

    test('a run missing an axis cannot be placed', () {
      final frontier = RunSweep.paretoFrontier([_point('placed', score: 0.5, tokens: 1000), _point('no cost', score: 0.9)]);
      expect(frontier, {'placed'});
    });
  });

  test('the table says it does not test, because it has no intervals', () {
    final markdown = RunSweep.toMarkdown([_point('a', score: 0.4, tokens: 10000), _point('b', score: 0.8, tokens: 60000)]);
    expect(markdown, contains('No confidence intervals'));
    expect(markdown, contains('aib compare'));
    // Both are on the frontier here, so both rows are marked.
    expect('✓'.allMatches(markdown).length, 2);
  });

  test('a locally priced run says the money column is not the whole cost', () {
    final markdown = RunSweep.toMarkdown([
      _point('local', score: 0.4, tokens: 10000, nominallyPriced: {'qwen3:8b'}),
      _point('hosted', score: 0.8, tokens: 60000),
    ]);
    expect(markdown, contains('cost_usd` is API spend only'));
    expect(markdown, contains('qwen3:8b'));
  });

  test('the plot fills the frontier and leaves out a run it cannot place', () {
    final svg = RunSweep.toSvg([
      _point('cheap', score: 0.4, tokens: 10000),
      _point('good', score: 0.8, tokens: 60000),
      _point('dominated', score: 0.5, tokens: 70000),
      _point('no cost', score: 0.9),
    ]);
    expect('fill="#3182ce"'.allMatches(svg).length, 2);
    expect('fill="white"'.allMatches(svg).length, 1);
    expect(svg, contains('<polyline'));
    expect(svg, isNot(contains('no cost')));
    expect(RunSweep.toHtml([_point('a<b', score: 0.5, tokens: 1)]), contains('a&lt;b'));
  });

  test('a fully hosted sweep says nothing about pricing', () {
    final markdown = RunSweep.toMarkdown([_point('a', score: 0.4, tokens: 10000), _point('b', score: 0.8, tokens: 60000)]);
    expect(markdown, isNot(contains('API spend only')));
  });
}
