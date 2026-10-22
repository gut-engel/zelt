import 'dart:async';
import 'dart:isolate';

/// A long-lived background isolate for CPU-heavy crypto (onion layers,
/// Argon2id, ML-KEM), so relaying never blocks the UI thread.
///
/// Jobs are closures; isolates in the same group can exchange them. Each
/// closure must only capture sendable data (bytes, plain objects).
class Worker {
  Worker._();

  static Future<SendPort>? _port;
  static final Map<int, Completer<Object?>> _pending = {};
  static int _next = 0;
  static RawReceivePort? _replies;

  /// Run jobs inline instead (useful where isolates are unavailable).
  static bool inline = false;

  static Future<SendPort> _start() {
    final ready = Completer<SendPort>();
    _replies = RawReceivePort((Object? msg) {
      if (msg is SendPort) {
        ready.complete(msg);
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
    Isolate.spawn(_main, _replies!.sendPort, debugName: 'zelt-crypto', errorsAreFatal: false);
    return ready.future;
  }

  static Future<void> _main(SendPort reply) async {
    final jobs = ReceivePort();
    reply.send(jobs.sendPort);
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
    final port = await (_port ??= _start());
    final id = _next++;
    final c = Completer<Object?>();
    _pending[id] = c;
    port.send((id, () async => await job()));
    return (await c.future) as T;
  }
}
