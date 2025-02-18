// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../../backend/live_test.dart';
import '../../backend/state.dart';
import '../../utils.dart';
import '../../utils.dart' as utils;
import '../engine.dart';
import '../load_exception.dart';
import '../load_suite.dart';
import '../reporter.dart';

/// The maximum console line length.
///
/// Lines longer than this will be cropped.
const _lineLength = 100;

/// A reporter that prints test results to the console in a single
/// continuously-updating line.
class CompactReporter implements Reporter {
  /// Whether the reporter should emit terminal color escapes.
  final bool _color;

  /// The terminal escape for green text, or the empty string if this is Windows
  /// or not outputting to a terminal.
  final String _green;

  /// The terminal escape for red text, or the empty string if this is Windows
  /// or not outputting to a terminal.
  final String _red;

  /// The terminal escape for yellow text, or the empty string if this is
  /// Windows or not outputting to a terminal.
  final String _yellow;

  /// The terminal escape for gray text, or the empty string if this is
  /// Windows or not outputting to a terminal.
  final String _gray;

  /// The terminal escape for bold text, or the empty string if this is
  /// Windows or not outputting to a terminal.
  final String _bold;

  /// The terminal escape for removing test coloring, or the empty string if
  /// this is Windows or not outputting to a terminal.
  final String _noColor;

  /// Whether to use verbose stack traces.
  final bool _verboseTrace;

  /// The engine used to run the tests.
  final Engine _engine;

  /// Whether the path to each test's suite should be printed.
  final bool _printPath;

  /// Whether the platform each test is running on should be printed.
  final bool _printPlatform;

  /// A stopwatch that tracks the duration of the full run.
  final _stopwatch = new Stopwatch();

  /// Whether we've started [_stopwatch].
  ///
  /// We can't just use `_stopwatch.isRunning` because the stopwatch is stopped
  /// when the reporter is paused.
  var _stopwatchStarted = false;

  /// The size of `_engine.passed` last time a progress notification was
  /// printed.
  int _lastProgressPassed;

  /// The size of `_engine.skipped` last time a progress notification was printed.
  int _lastProgressSkipped;

  /// The size of `_engine.failed` last time a progress notification was
  /// printed.
  int _lastProgressFailed;

  /// The duration of the test run in seconds last time a progress notification
  /// was printed.
  int _lastProgressElapsed;

  /// The message printed for the last progress notification.
  String _lastProgressMessage;

  /// Whether the message printed for the last progress notification was
  /// truncated.
  bool _lastProgressTruncated;

  // Whether a newline has been printed since the last progress line.
  var _printedNewline = true;

  /// Whether the reporter is paused.
  var _paused = false;

  /// The set of all subscriptions to various streams.
  final _subscriptions = new Set<StreamSubscription>();

  /// Watches the tests run by [engine] and prints their results to the
  /// terminal.
  ///
  /// If [color] is `true`, this will use terminal colors; if it's `false`, it
  /// won't. If [verboseTrace] is `true`, this will print core library frames.
  /// If [printPath] is `true`, this will print the path name as part of the
  /// test description. Likewise, if [printPlatform] is `true`, this will print
  /// the platform as part of the test description.
  static CompactReporter watch(Engine engine, {bool color: true,
      bool verboseTrace: false, bool printPath: true,
      bool printPlatform: true}) {
    return new CompactReporter._(
        engine,
        color: color,
        verboseTrace: verboseTrace,
        printPath: printPath,
        printPlatform: printPlatform);
  }

  CompactReporter._(this._engine, {bool color: true, bool verboseTrace: false,
          bool printPath: true, bool printPlatform: true})
      : _verboseTrace = verboseTrace,
        _printPath = printPath,
        _printPlatform = printPlatform,
        _color = color,
        _green = color ? '\u001b[32m' : '',
        _red = color ? '\u001b[31m' : '',
        _yellow = color ? '\u001b[33m' : '',
        _gray = color ? '\u001b[1;30m' : '',
        _bold = color ? '\u001b[1m' : '',
        _noColor = color ? '\u001b[0m' : '' {
    _subscriptions.add(_engine.onTestStarted.listen(_onTestStarted));

    /// Convert the future to a stream so that the subscription can be paused or
    /// canceled.
    _subscriptions.add(_engine.success.asStream().listen(_onDone));
  }

  void pause() {
    if (_paused) return;
    _paused = true;

    if (!_printedNewline) print('');
    _printedNewline = true;
    _stopwatch.stop();

    // Force the next message to be printed, even if it's identical to the
    // previous one. If the reporter was paused, text was probably printed
    // during the pause.
    _lastProgressMessage = null;

    for (var subscription in _subscriptions) {
      subscription.pause();
    }
  }

  void resume() {
    if (!_paused) return;
    _paused = false;

    if (_stopwatchStarted) _stopwatch.start();

    for (var subscription in _subscriptions) {
      subscription.resume();
    }
  }

  void cancel() {
    for (var subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  /// A callback called when the engine begins running [liveTest].
  void _onTestStarted(LiveTest liveTest) {
    if (!_stopwatchStarted) {
      _stopwatchStarted = true;
      _stopwatch.start();
      /// Keep updating the time even when nothing else is happening.
      _subscriptions.add(new Stream.periodic(new Duration(seconds: 1))
          .listen((_) => _progressLine(_lastProgressMessage)));
    }

    // If this is the first test to start, print a progress line so the user
    // knows what's running. It's possible that the active test may not be
    // [liveTest] because the engine doesn't always surface load tests.
    if (_engine.active.length == 1 && _engine.active.first == liveTest) {
      _progressLine(_description(liveTest));
    }

    _subscriptions.add(liveTest.onStateChange
        .listen((state) => _onStateChange(liveTest, state)));

    _subscriptions.add(liveTest.onError.listen((error) =>
        _onError(liveTest, error.error, error.stackTrace)));

    _subscriptions.add(liveTest.onPrint.listen((line) {
      _progressLine(_description(liveTest), truncate: false);
      if (!_printedNewline) print('');
      _printedNewline = true;

      print(line);
    }));
  }

  /// A callback called when [liveTest]'s state becomes [state].
  void _onStateChange(LiveTest liveTest, State state) {
    if (state.status != Status.complete) return;

    if (state.result == Result.skipped &&
        liveTest.test.metadata.skipReason != null) {
      _progressLine(_description(liveTest));
      print('');
      print(indent('${_yellow}Skip: ${liveTest.test.metadata.skipReason}'
          '$_noColor'));
    } else {
      // Always display the name of the oldest active test, unless testing
      // is finished in which case display the last test to complete.
      if (_engine.active.isEmpty) {
        _progressLine(_description(liveTest));
      } else {
        _progressLine(_description(_engine.active.first));
      }
    }
  }

  /// A callback called when [liveTest] throws [error].
  void _onError(LiveTest liveTest, error, StackTrace stackTrace) {
    if (liveTest.state.status != Status.complete) return;

    _progressLine(_description(liveTest), truncate: false);
    if (!_printedNewline) print('');
    _printedNewline = true;

    if (error is! LoadException) {
      print(indent(error.toString()));
      var chain = terseChain(stackTrace, verbose: _verboseTrace);
      print(indent(chain.toString()));
      return;
    }

    print(indent(error.toString(color: _color)));

    // Only print stack traces for load errors that come from the user's code.
    if (error.innerError is! IOException &&
        error.innerError is! IsolateSpawnException &&
        error.innerError is! FormatException &&
        error.innerError is! String) {
      print(indent(terseChain(stackTrace).toString()));
    }
  }

  /// A callback called when the engine is finished running tests.
  ///
  /// [success] will be `true` if all tests passed, `false` if some tests
  /// failed, and `null` if the engine was closed prematurely.
  void _onDone(bool success) {
    cancel();
    _stopwatch.stop();

    // A null success value indicates that the engine was closed before the
    // tests finished running, probably because of a signal from the user. We
    // shouldn't print summary information, we should just make sure the
    // terminal cursor is on its own line.
    if (success == null) {
      if (!_printedNewline) print("");
      _printedNewline = true;
      return;
    }

    if (_engine.liveTests.isEmpty) {
      if (!_printedNewline) stdout.write("\r");
      var message = "No tests ran.";
      stdout.write(message);

      // Add extra padding to overwrite any load messages.
      if (!_printedNewline) stdout.write(" " * (_lineLength - message.length));
      stdout.writeln();
    } else if (!success) {
      _progressLine('Some tests failed.', color: _red);
      print('');
    } else if (_engine.passed.isEmpty) {
      _progressLine("All tests skipped.");
      print('');
    } else {
      _progressLine("All tests passed!");
      print('');
    }
  }

  /// Prints a line representing the current state of the tests.
  ///
  /// [message] goes after the progress report, and may be truncated to fit the
  /// entire line within [_lineLength]. If [color] is passed, it's used as the
  /// color for [message].
  bool _progressLine(String message, {String color, bool truncate: true}) {
    var elapsed = _stopwatch.elapsed.inSeconds;

    // Print nothing if nothing has changed since the last progress line.
    if (_engine.passed.length == _lastProgressPassed &&
        _engine.skipped.length == _lastProgressSkipped &&
        _engine.failed.length == _lastProgressFailed &&
        message == _lastProgressMessage &&
        // Don't re-print just because the message became re-truncated, because
        // that doesn't add information.
        (truncate || !_lastProgressTruncated) &&
        // If we printed a newline, that means the last line *wasn't* a progress
        // line. In that case, we don't want to print a new progress line just
        // because the elapsed time changed.
        (_printedNewline || elapsed == _lastProgressElapsed)) {
      return false;
    }

    _lastProgressPassed = _engine.passed.length;
    _lastProgressSkipped = _engine.skipped.length;
    _lastProgressFailed = _engine.failed.length;
    _lastProgressElapsed = elapsed;
    _lastProgressMessage = message;
    _lastProgressTruncated = truncate;

    if (color == null) color = '';
    var duration = _stopwatch.elapsed;
    var buffer = new StringBuffer();

    // \r moves back to the beginning of the current line.
    buffer.write('\r${_timeString(duration)} ');
    buffer.write(_green);
    buffer.write('+');
    buffer.write(_engine.passed.length);
    buffer.write(_noColor);

    if (_engine.skipped.isNotEmpty) {
      buffer.write(_yellow);
      buffer.write(' ~');
      buffer.write(_engine.skipped.length);
      buffer.write(_noColor);
    }

    if (_engine.failed.isNotEmpty) {
      buffer.write(_red);
      buffer.write(' -');
      buffer.write(_engine.failed.length);
      buffer.write(_noColor);
    }

    buffer.write(': ');
    buffer.write(color);

    // Ensure the line fits within [_lineLength]. [buffer] includes the color
    // escape sequences too. Because these sequences are not visible characters,
    // we make sure they are not counted towards the limit.
    var length = withoutColors(buffer.toString()).length;
    if (truncate) message = utils.truncate(message, _lineLength - length);
    buffer.write(message);
    buffer.write(_noColor);

    // Pad the rest of the line so that it looks erased.
    buffer.write(' ' * (_lineLength - withoutColors(buffer.toString()).length));
    stdout.write(buffer.toString());

    _printedNewline = false;
    return true;
  }

  /// Returns a representation of [duration] as `MM:SS`.
  String _timeString(Duration duration) {
    return "${duration.inMinutes.toString().padLeft(2, '0')}:"
        "${(duration.inSeconds % 60).toString().padLeft(2, '0')}";
  }

  /// Returns a description of [liveTest].
  ///
  /// This differs from the test's own description in that it may also include
  /// the suite's name.
  String _description(LiveTest liveTest) {
    var name = liveTest.test.name;

    if (_printPath && liveTest.suite is! LoadSuite &&
        liveTest.suite.path != null) {
      name = "${liveTest.suite.path}: $name";
    }

    if (_printPlatform && liveTest.suite.platform != null) {
      name = "[${liveTest.suite.platform.name}] $name";
    }

    if (liveTest.suite is LoadSuite) name = "$_bold$_gray$name$_noColor";

    return name;
  }
}
