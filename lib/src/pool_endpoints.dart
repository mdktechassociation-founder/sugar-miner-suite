/// Pool endpoints, tried in order. The developer never picks one; the SDK keeps
/// a healthy one and moves on when a pool stops answering.
class PoolEndpoint {
  final String host;
  final int port;
  final String label;
  const PoolEndpoint(this.host, this.port, this.label);

  @override
  String toString() => '$host:$port';
}

/// What ships with the SDK, and what the health checks reorder.
class PoolEndpoints {
  static const pooLab = PoolEndpoint('stratum.poolab.org', 8451, 'PooLab');
  static const zpool = PoolEndpoint('mine.zpool.ca', 6241, 'zpool');
  static const zergpool = PoolEndpoint('mine.zergpool.com', 4499, 'zergpool');

  /// Default for Sugarchain (yespowerSUGAR). The second entry uses the
  /// `c=SUGAR` password convention that those pools want — the miner sets it.
  static const defaults = <PoolEndpoint>[pooLab, zpool, zergpool];

  static const int _maxFailuresBeforeMovingOn = 2;
}

/// Tracks which endpoint is actually working and rotates on failure.
class EndpointRotator {
  final List<PoolEndpoint> endpoints;
  int _index = 0;
  int _failures = 0;
  final Map<String, int> failures = <String, int>{};

  EndpointRotator(List<PoolEndpoint>? configured)
      : endpoints = (configured == null || configured.isEmpty)
            ? PoolEndpoints.defaults
            : List<PoolEndpoint>.from(configured);

  PoolEndpoint get current => endpoints[_index % endpoints.length];

  void reportSuccess() {
    _failures = 0;
    failures.remove(current.toString());
  }

  void reportFailure() {
    _failures++;
    failures[current.toString()] = (failures[current.toString()] ?? 0) + 1;
    if (_failures >= PoolEndpoints._maxFailuresBeforeMovingOn && endpoints.length > 1) {
      _index = (_index + 1) % endpoints.length;
      _failures = 0;
    }
  }

  /// Password some pools need to know which coin to pay in.
  String passwordFor(PoolEndpoint e) =>
      e.host.contains('zpool') || e.host.contains('zergpool') ? 'c=SUGAR' : 'x';
}
