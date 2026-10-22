import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// A long-lived background isolate for CPU-heavy crypto (onion layers,
/// Argon2id, ML-KEM), so relaying never blocks the UI thread.
///
/// Jobs are closures; isolates in the same group can exchange them. Each
/// closure must only capture sendable data (bytes, plain objects).
class Worker {
  Worker._();

  /// Number of worker isolates. Jobs are independent, so they spread over all
  /// of them. Set before the first job (e.g. from ZELT_WORKERS on a relay).
  static int size = (Platform.numberOfProcessors - 1).clamp(1, 4);

  static List<Future<SendPort>>? _ports;
  static final Map<int, Completer<Object?>> _pending = {};
  static int _next = 0;
  static RawReceivePort? _replies;
  static final Map<int, Completer<SendPort>> _ready = {};

  /// Run jobs inline instead (useful where isolates are unavailable).
  static bool inline = false;

  static List<Future<SendPort>> _start() {
    _replies = RawReceivePort((Object? msg) {
      if (msg is (int, SendPort)) {
        _ready.remove(msg.$1)?.complete(msg.$2);
        return;
      }
      final (id, ok, value) = msg as (int, bool, Object?);
      final c = _pending.remove(id);
      if (c == null) return;
      if (ok) {
        c.complete(value);
      } else {
        c.completeError(value ?? StateError('worker job failed'));
      }
    });
    return [
      for (var i = 0; i < size; i++) _spawn(i),
    ];
  }

  static Future<SendPort> _spawn(int i) {
    final c = Completer<SendPort>();
    _ready[i] = c;
    Isolate.spawn(_main, (i, _replies!.sendPort), debugName: 'zelt-crypto-$i', errorsAreFatal: false);
    return c.future;
  }

  static Future<void> _main((int, SendPort) init) async {
    final (index, reply) = init;
    final jobs = ReceivePort();
    reply.send((index, jobs.sendPort));
    await for (final msg in jobs) {
      final (id, job) = msg as (int, Future<Object?> Function());
      try {
        reply.send((id, true, await job()));
      } catch (e) {
        reply.send((id, false, e.toString()));
      }
    }
  }

  static Future<T> run<T>(FutureOr<T> Function() job) async {
    if (inline) return await job();
    final ports = _ports ??= _start();
    final id = _next++;
    final port = await ports[id % ports.length];
    final c = Completer<Object?>();
    _pending[id] = c;
    port.send((id, () async => await job()));
    return (await c.future) as T;
  }
}
