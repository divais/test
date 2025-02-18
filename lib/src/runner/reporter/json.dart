// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import '../../backend/group.dart';
import '../../backend/group_entry.dart';
import '../../backend/live_test.dart';
import '../../backend/metadata.dart';
import '../../backend/state.dart';
import '../../backend/suite.dart';
import '../../backend/test_platform.dart';
import '../../frontend/expect.dart';
import '../../utils.dart';
import '../engine.dart';
import '../load_suite.dart';
import '../reporter.dart';
import '../version.dart';

/// A reporter that prints machine-readable JSON-formatted test results.
class JsonReporter implements Reporter {
  /// Whether to use verbose stack traces.
  final bool _verboseTrace;

  /// Whether to emit location information for JS tests.
  final bool _jsLocations;

  /// The engine used to run the tests.
  final Engine _engine;

  /// A stopwatch that tracks the duration of the full run.
  final _stopwatch = new Stopwatch();

  /// Whether we've started [_stopwatch].
  ///
  /// We can't just use `_stopwatch.isRunning` because the stopwatch is stopped
  /// when the reporter is paused.
  var _stopwatchStarted = false;

  /// Whether the reporter is paused.
  var _paused = false;

  /// The set of all subscriptions to various streams.
  final _subscriptions = new Set<StreamSubscription>();

  /// An expando that associates unique IDs with [LiveTest]s.
  final _liveTestIDs = new Map<LiveTest, int>();

  /// An expando that associates unique IDs with [Suite]s.
  final _suiteIDs = new Map<Suite, int>();

  /// An expando that associates unique IDs with [Group]s.
  final _groupIDs = new Map<Group, int>();

  /// The next ID to associate with a [LiveTest].
  var _nextID = 0;

  /// Watches the tests run by [engine] and prints their results as JSON.
  ///
  /// If [verboseTrace] is `true`, this will print core library frames. If
  /// [jsLocations] is `false`, this will not emit location information for JS
  /// tests.
  static JsonReporter watch(Engine engine, {bool verboseTrace: false,
      bool jsLocations: true}) {
    return new JsonReporter._(engine,
        verboseTrace: verboseTrace, jsLocations: jsLocations);
  }

  JsonReporter._(this._engine, {bool verboseTrace: false,
      bool jsLocations: true})
      : _verboseTrace = verboseTrace,
        _jsLocations = jsLocations {
    _subscriptions.add(_engine.onTestStarted.listen(_onTestStarted));

    /// Convert the future to a stream so that the subscription can be paused or
    /// canceled.
    _subscriptions.add(_engine.success.asStream().listen(_onDone));

    _subscriptions.add(_engine.onSuiteAdded.listen(null, onDone: () {
      _emit("allSuites", {
        "count": _engine.addedSuites.length
      });
    }));

    _emit("start", {
      "protocolVersion": "0.1.0",
      "runnerVersion": testVersion
    });
  }

  void pause() {
    if (_paused) return;
    _paused = true;

    _stopwatch.stop();

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
    }

    var suiteID = _idForSuite(liveTest.suite);

    // Don't emit groups for load suites. They're always empty and they provide
    // unnecessary clutter.
    var groupIDs = liveTest.suite is LoadSuite
        ? []
        : _idsForGroups(liveTest.groups, liveTest.suite);

    var id = _nextID++;
    _liveTestIDs[liveTest] = id;
    _emit("testStart", {
      "test": _addFrameInfo({
        "id": id,
        "name": liveTest.test.name, 
        "suiteID": suiteID,
        "groupIDs": groupIDs,
        "metadata": _serializeMetadata(liveTest.test.metadata)
      }, liveTest.test, liveTest.suite.platform)
    });

    /// Convert the future to a stream so that the subscription can be paused or
    /// canceled.
    _subscriptions.add(liveTest.onComplete.asStream().listen((_) =>
        _onComplete(liveTest)));

    _subscriptions.add(liveTest.onError.listen((error) =>
        _onError(liveTest, error.error, error.stackTrace)));

    _subscriptions.add(liveTest.onPrint.listen((line) {
      _emit("print", {
        "testID": id,
        "message": line
      });
    }));
  }

  /// Returns an ID for [suite].
  ///
  /// If [suite] doesn't have an ID yet, this assigns one and emits a new event
  /// for that suite.
  int _idForSuite(Suite suite) {
    if (_suiteIDs.containsKey(suite)) return _suiteIDs[suite];

    var id = _nextID++;
    _suiteIDs[suite] = id;

    // Give the load suite's suite the same ID, because it doesn't have any
    // different metadata.
    if (suite is LoadSuite) {
      suite.suite.then((runnerSuite) {
        if (runnerSuite != null) _suiteIDs[runnerSuite] = id;
      });
    }

    _emit("suite", {
      "suite": {
        "id": id,
        "platform": suite.platform?.identifier,
        "path": suite.path
      }
    });
    return id;
  }

  /// Returns a list of the IDs for all the groups in [groups], which are
  /// contained in the suite identified by [suiteID].
  ///
  /// If a group doesn't have an ID yet, this assigns one and emits a new event
  /// for that group.
  List<int> _idsForGroups(Iterable<Group> groups, Suite suite) {
    int parentID;
    return groups.map((group) {
      if (_groupIDs.containsKey(group)) {
        parentID = _groupIDs[group];
        return parentID;
      }

      var id = _nextID++;
      _groupIDs[group] = id;

      _emit("group", {
        "group": _addFrameInfo({
          "id": id,
          "suiteID": _idForSuite(suite),
          "parentID": parentID,
          "name": group.name,
          "metadata": _serializeMetadata(group.metadata),
          "testCount": group.testCount
        }, group, suite.platform)
      });
      parentID = id;
      return id;
    }).toList();
  }

  /// Serializes [metadata] into a JSON-protocol-compatible map.
  Map _serializeMetadata(Metadata metadata) =>
      {"skip": metadata.skip, "skipReason": metadata.skipReason};

  /// A callback called when [liveTest] finishes running.
  void _onComplete(LiveTest liveTest) {
    _emit("testDone", {
      "testID": _liveTestIDs[liveTest],
      // For backwards-compatibility, report skipped tests as successes.
      "result": liveTest.state.result == Result.skipped
          ? "success"
          : liveTest.state.result.toString(),
      "skipped": liveTest.state.result == Result.skipped,
      "hidden": !_engine.liveTests.contains(liveTest)
    });
  }

  /// A callback called when [liveTest] throws [error].
  void _onError(LiveTest liveTest, error, StackTrace stackTrace) {
    _emit("error", {
      "testID": _liveTestIDs[liveTest],
      "error": error.toString(),
      "stackTrace": terseChain(stackTrace, verbose: _verboseTrace).toString(),
      "isFailure": error is TestFailure
    });
  }

  /// A callback called when the engine is finished running tests.
  ///
  /// [success] will be `true` if all tests passed, `false` if some tests
  /// failed, and `null` if the engine was closed prematurely.
  void _onDone(bool success) {
    cancel();
    _stopwatch.stop();

    _emit("done", {"success": success});
  }

  /// Emits an event with the given type and attributes.
  void _emit(String type, Map attributes) {
    attributes["type"] = type;
    attributes["time"] = _stopwatch.elapsed.inMilliseconds;
    print(JSON.encode(attributes));
  }

  /// Modifies [map] to include line, column, and URL information from the first
  /// frame of [entry.trace].
  ///
  /// Returns [map].
  Map<String, dynamic> _addFrameInfo(Map<String, dynamic> map,
      GroupEntry entry, TestPlatform platform) {
    var frame = entry.trace?.frames?.first;
    if (!_jsLocations && platform.isJS) frame = null;

    map["line"] = frame?.line;
    map["column"] = frame?.column;
    map["url"] = frame?.uri?.toString();
    return map;
  }
}
