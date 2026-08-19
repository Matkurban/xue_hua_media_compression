/// 一次压缩会话：可听进度、等待结果、取消、释放。
///
/// One compression session: listen to progress, await the result, cancel, dispose.
abstract interface class CompressionSession<TResult> {
  /// 压缩进度，范围 0.0–1.0。
  ///
  /// Compression progress in the range 0.0–1.0.
  ///
  /// **接收 / Receives**
  /// 无参数。订阅后会先收到原生在 listen 前缓冲的最新一条进度（若有）。
  /// No parameters. After listening, the latest buffered progress (if any) is replayed.
  ///
  /// **返回 / Returns**
  /// 广播流。由原生经 EventChannel 上报，Dart 不轮询。
  /// A broadcast stream. Native code pushes events; Dart does not poll.
  Stream<double> get progress;

  /// 成功完成时得到结果；失败或取消时抛 [MediaCompressionException]。
  ///
  /// Completes with the result, or throws [MediaCompressionException] on failure/cancel.
  Future<TResult> get result;

  /// 请求中止本次压缩。
  ///
  /// Requests that this compression abort.
  ///
  /// **接收 / Receives**
  /// 无参数。
  /// No parameters.
  ///
  /// **返回 / Returns**
  /// 当取消请求已交给原生时完成。已结束则立即返回（幂等）。
  /// Completes when the cancel request has been delivered. No-op if already finished.
  ///
  /// **抛出 / Throws**
  /// 本方法本身不抛业务错误；取消成功后 [result] 抛 `cancelled`。
  /// This method does not throw business errors; [result] throws `cancelled`.
  Future<void> cancel();

  /// 释放原生会话。
  ///
  /// Releases the native session.
  ///
  /// **接收 / Receives**
  /// 无参数。可重复调用。
  /// No parameters. Safe to call more than once.
  ///
  /// **返回 / Returns**
  /// 释放完成后完成。已释放则立即返回。
  /// Completes when released. Returns immediately if already disposed.
  ///
  /// **抛出 / Throws**
  /// dispose 之后再调用 [cancel] 以外的使用方式，由门面抛 [StateError]。
  /// Using the session after dispose (other than [cancel]/[dispose]) throws [StateError].
  Future<void> dispose();
}
