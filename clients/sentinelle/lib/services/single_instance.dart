import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Stops a second copy of the app from starting.
///
/// This matters more here than in an ordinary app: two instances would each
/// start their own core, fight over the same local ports, and take turns
/// rewriting the system proxy — and whichever one the user closes last would
/// restore settings the other still needs.
///
/// Detection is a loopback listener rather than a lock file, because the
/// running instance also has to be *told* to come to the front, and a lock
/// gives no channel for that. A crashed process releases its socket the same
/// way it releases a lock, so there is nothing stale to clean up.
class SingleInstance {
  /// Chosen from the dynamic/private range and fixed so both instances agree.
  static const port = 49726;

  /// Sent by the primary so a second launch can tell "our app already has this
  /// port" from "something unrelated is using it".
  ///
  /// Without the handshake, an unrelated program holding the port would make
  /// the app refuse to start at all — a far worse failure than the one being
  /// prevented.
  static const _hello = 'sentinelle-instance-v1';

  static ServerSocket? _server;

  /// Returns true when this process should carry on running.
  ///
  /// [onSecondLaunch] fires on the primary each time another launch is turned
  /// away, which is the moment to raise the window — that is what the user was
  /// trying to do by opening the app again.
  static Future<bool> claim({required void Function() onSecondLaunch}) async {
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server!.listen(
        (socket) {
          socket.write(_hello);
          socket.close();
          onSecondLaunch();
        },
        onError: (Object _) {},
        cancelOnError: false,
      );
      return true;
    } on SocketException {
      // The port is taken. Only stand down if it is taken by us.
      return !await _primaryIsOurs();
    } catch (_) {
      // Never let this check be the reason the app will not open.
      return true;
    }
  }

  static Future<bool> _primaryIsOurs() async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 800),
      );
      final reply = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(milliseconds: 800));
      return reply.trim() == _hello;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  static Future<void> release() async {
    await _server?.close();
    _server = null;
  }
}
