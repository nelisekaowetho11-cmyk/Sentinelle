class V2RayStatus {
  final String duration;
  final int uploadSpeed;
  final int downloadSpeed;
  final int upload;
  final int download;
  final String state;

  /// Veil: true when the stop being reported was asked for — the ongoing
  /// notification's DISCONNECT button, the quick settings tile, the home
  /// screen widget, or the app itself.
  ///
  /// Only the core's own process knows, and this event is the only thing that
  /// leaves it, so the answer travels with the state rather than being asked
  /// for afterwards. Meaningless on any state other than DISCONNECTED.
  final bool userRequestedStop;

  V2RayStatus({
    this.duration = "00:00:00",
    this.uploadSpeed = 0,
    this.downloadSpeed = 0,
    this.upload = 0,
    this.download = 0,
    this.state = "DISCONNECTED",
    this.userRequestedStop = false,
  });
}
