import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'colmi_ring.dart' as ring;

enum ControllerState {
  scanning,
  connecting,
  idle, // (Connected, shake to wake, disable polling)
  verifyIntentionalWakeup, // Shake detected, Start polling accelerometer for rotation, times out back to idle
  userInput, // User did full rotation, start taking input (or else back to idle) continue polling accelerometer for menu selection
  verifyIntentionalSelection, // after user tap, ensure one more full rotation to confirm, generate selection event then back to idle, or else time out back to idle
  // Or else multiple chained selection actions; does the host app tell the controller to go straight back to userInput state in its OnSelected event handler? (As long as the controller is in Idle?)
  disconnected, // doesn't necessarily auto-reconnect
}

enum ControlEvent {
  none,
  scrollUp,
  scrollDown,
  provisionalSelect,
  verifySelect25,
  verifySelect50,
  verifySelect75,
  confirmSelect,
  timeout,
}

/// Finds, connects to and sets up a Colmi R0x ring as a controller for input.
class ColmiR0xController {

  StreamSubscription<List<ScanResult>>? _scanResultSubs; // device scan subscription
  StreamSubscription<List<int>>? _charNotifySubs; // custom notify stream subscription
  StreamSubscription<BluetoothConnectionState>? _connStateSubs; // device connection state subscription

  BluetoothDevice? _device;
  BluetoothCharacteristic? _charWrite; // custom write
  BluetoothCharacteristic? _charNotify; // custom notify

  ControllerState _currentState = ControllerState.disconnected;
  Function stateListener;
  Function controlEventListener;
  Function? rawEventListener;

  bool _pollRawDataOn = false;
  int _lastUpdateTime = 0;
  int _accelMillis = 0;

  // keep the previous 2 values as history for detecting taps and scrolls
  // [0] has the older value, [1] is the newer
  final _rawX = [0, 0];
  final _rawY = [0, 0];
  final _rawZ = [0, 0];
  final _rawNetGforce = [0.0, 0.0];
  final _filteredNetGforce = [0.0, 0.0];
  final _rawScrollPosition = [0.0, 0.0];
  final _filteredScrollPosition = [0.0, 0.0];

  /// Take StateListener and ControlEventListener callback functions?
  ColmiR0xController(this.stateListener, this.controlEventListener, {this.rawEventListener});

  /// Scan, connect, discover characteristics and transition to ControllerState.idle if possible
  Future<void> connect() async {
    assert(_currentState == ControllerState.disconnected);

    // if we've previously connected, just reconnect, don't scan
    if (_device != null) {
      await _reconnect();
      return;
    }

    await _scanAndConnect();
  }

  /// Disconnect from the ring and cancel the notification subscription
  Future<void> disconnect() async {
    await _charNotifySubs?.cancel();
    await _device?.disconnect();
    _charWrite = null;
    _charNotify = null;
    _transitionTo(ControllerState.disconnected);
  }

  /// Private method for reconnecting to a known device
  Future<void> _reconnect() async {
    try {
      await _device!.connect(); // TODO any hope of forcing a faster connection to try to improve on 250ms polling?
      await _device!.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
      await _device!.requestMtu(32);
      await _discoverServices();
      _transitionTo(ControllerState.idle);
    } catch (e) {
      debugPrint('Error occurred while connecting: $e');
      // TODO if Android error 133
      // TODO connectionStateListener should attempt another reconnection?
    }
  }

  /// Private method for scanning and connecting to a device for the first time
  Future<void> _scanAndConnect() async {
    try {
      // Wait for Bluetooth enabled & permission granted
      await FlutterBluePlus.adapterState.where((val) => val == BluetoothAdapterState.on).first;

      // guessing that all the rings advertise a name of R0* based on my R06
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 5),
        withKeywords: ['R0']);
      _transitionTo(ControllerState.scanning);
    } catch (e) {
      debugPrint(e.toString());
      _transitionTo(ControllerState.disconnected);
    }

    // Listen to scan results
    // if there's already a subscription, remember to cancel it first if we can
    // Connects to the first one; if you have several rings in range then tweak this
    await _scanResultSubs?.cancel();
    _scanResultSubs = FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        // not quite sure if all the rings follow 'R0n_xxxx' but my R06 does
        if (r.advertisementData.advName.startsWith(RegExp(ring.advertisedNamePattern))) {
          FlutterBluePlus.stopScan();
          _device = r.device;
          _transitionTo(ControllerState.connecting);

          try {
            // firstly set up a subscription to track connections/disconnections from the ring
            _connStateSubs = _device!.connectionState.listen((BluetoothConnectionState state) async {
                debugPrint('device connection state change: $state');
                if (state == BluetoothConnectionState.disconnected) {
                  DisconnectReason? reason = _device!.disconnectReason;

                  if (reason != null) {
                    debugPrint('device disconnection reason: ${_device!.disconnectReason}');
                    if (reason.platform == ErrorPlatform.android && reason.code == 133) {
                      debugPrint('ANDROID_SPECIFIC_ERROR occurred. Multiple attempts to reconnect (3+) usually solve it.');
                      _reconnect();
                    }
                  }
                }
            });

            _device!.cancelWhenDisconnected(_connStateSubs!, delayed:true, next:true);

            _reconnect();
          }
          catch (e) {
            debugPrint(e.toString());
            _transitionTo(ControllerState.disconnected);
          }
          break;
        }
      }
    });
  }

  /// Find and keep references to the custom write and notify characteristics
  Future<void> _discoverServices() async {
    if (_device != null && _device!.isConnected) {
      List<BluetoothService> services = await _device!.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.str128 == ring.Uuid.cmdService.str128) {
          for (BluetoothCharacteristic c in service.characteristics) {
            // Find the Char for writing 16-byte commands to the ring
            if (c.uuid.str128 == ring.Uuid.cmdWriteChar.str128) {
              _charWrite = c;
            }
            // Find the Char for receiving 16-byte notifications from the ring and subscribe
            else if (c.uuid.str128 == ring.Uuid.cmdNotifyChar.str128) {
              _charNotify = c;
              // if there's already a subscription, remember to cancel the old one first if we can
              await _charNotifySubs?.cancel();
              _charNotifySubs = _charNotify!.onValueReceived.listen(_onNotificationData);
              await _charNotify!.setNotifyValue(true);
            }
          }
        }
      }
    }
  }

  void _transitionTo(ControllerState newState) {
    debugPrint('Transitioning from $_currentState to $newState');

    if (_currentState == ControllerState.connecting && newState == ControllerState.idle) {
      _enableWaveGestureDetection();
    }
    else if (_currentState == ControllerState.disconnected && newState == ControllerState.idle) {
      _enableWaveGestureDetection();
    }
    else if (_currentState == ControllerState.idle && newState == ControllerState.userInput) {
      // turn off wave detection
      _disableWaveGestureDetection();
      // turn on raw data polling
      _enableRawDataPolling();
    }
    else if (newState == ControllerState.disconnected) {
      _disableRawDataPolling();
    }

    _currentState = newState;
    stateListener.call(newState);
  }

  /// Callback for handling all 16-byte data notifications from the custom notification characteristic
  void _onNotificationData(List<int> data) {
    if (data.length != 16) {
      debugPrint('Invalid message length: ${data.length}');
      return;
    }

    // process accelerometer updates
    if (data[0] == ring.Notification.rawSensor.code &&
        data[1] == ring.RawSensorSubtype.accelerometer.code) {

      // only process during the relevant states
      if (_currentState == ControllerState.userInput ||
          _currentState == ControllerState.verifyIntentionalWakeup ||
          _currentState == ControllerState.verifyIntentionalSelection) {

        // track the time between accelerometer updates
        var receivedTime = DateTime.timestamp().millisecondsSinceEpoch;
        _accelMillis = receivedTime - _lastUpdateTime;
        _lastUpdateTime = receivedTime;

        // pull the raw values out of the bluetooth message payload
        var (rawX, rawY, rawZ) = ring.parseRawAccelerometerSensorData(data);

        // calculate how much acceleration other than gravity
        var rawNetGforce = (sqrt(rawX * rawX + rawY * rawY + rawZ * rawZ)/512 - 1.0).abs();
        var filteredNetGforce = 0.0;
        var rawScrollPosition = 0.0;
        var filteredScrollPosition = 0.0;

        // if this is just close to g, then the ring is at rest or perhaps gentle scrolling
        if (rawNetGforce < 0.1) {
          // calculate absolute "scroll" position when rotated around the finger
          // range -pi .. pi
          rawScrollPosition = atan2(rawY, rawX);
          filteredScrollPosition = rawScrollPosition;
          // keep filteredNetGforce at 0.0
        }
        else if (rawNetGforce > 0.15) {
          // if values are large, this might be a flick or tap, scroll position will be
          // unreliable so copy the previous scroll position
          // range > 0, in g
          filteredScrollPosition = _filteredScrollPosition[1];
          filteredNetGforce = rawNetGforce;
        }
        else {
          // ambiguous zone, just report the previous values
          filteredScrollPosition = _filteredScrollPosition[1];
          filteredNetGforce = _filteredNetGforce[1];
        }

        // work out if we have taps, scrolls or neither
        // we say it's a tap if it's large g-force that lasts for only one sample
        // && not if the last few scroll samples showed significant movement
        var isTap = (_filteredNetGforce[0] == 0.0) && (_filteredNetGforce[1] > 0.15) && (filteredNetGforce == 0.0)
          && (_scrollDistance(filteredScrollPosition, _filteredScrollPosition[1]) < 0.15)
          && (_scrollDistance(_filteredScrollPosition[1], _filteredScrollPosition[0]) < 0.15);

        // generate scroll events if the net gforce is low and there has been significant movement in the absolute scroll position
        var isScrollUp = (_filteredNetGforce[0] == 0.0) && (_scrollDistance(filteredScrollPosition, _filteredScrollPosition[1]) > 0.25);
        var isScrollDown = (_filteredNetGforce[0] == 0.0) && (_scrollDistance(filteredScrollPosition, _filteredScrollPosition[1]) < -0.25);

        // update previous values
        _rawX[0] = _rawX[1];
        _rawY[0] = _rawY[1];
        _rawZ[0] = _rawZ[1];
        _rawX[1] = rawX;
        _rawY[1] = rawY;
        _rawZ[1] = rawZ;

        _rawNetGforce[0] = _rawNetGforce[1];
        _rawNetGforce[1] = rawNetGforce;

        _rawScrollPosition[0] = _rawScrollPosition[1];
        _rawScrollPosition[1] = rawScrollPosition;

        _filteredNetGforce[0] = _filteredNetGforce[1];
        _filteredNetGforce[1] = filteredNetGforce;

        _filteredScrollPosition[0] = _filteredScrollPosition[1];
        _filteredScrollPosition[1] = filteredScrollPosition;

        // update the listener with the latest values
        rawEventListener?.call(rawX, rawY, rawZ, rawScrollPosition, filteredScrollPosition, rawNetGforce, filteredNetGforce, _accelMillis);
        if (isTap) controlEventListener.call(ControlEvent.provisionalSelect);
        if (isScrollUp) controlEventListener.call(ControlEvent.scrollUp);
        if (isScrollDown) controlEventListener.call(ControlEvent.scrollDown);

        // kick off the next request
        if (_pollRawDataOn) {
          _sendCommand(ring.Command.getAllRawData.bytes);
        }
      }
    }
    // process wave gesture updates
    else if (data[0] == ring.Notification.waveGesture.code) {
      if (data[1] == 2) {
        if (_currentState == ControllerState.idle) {
          _transitionTo(ControllerState.userInput);
        }
        else {
          debugPrint('Error: Wave Gesture Detected during unexpected state: $_currentState');
        }
      }
    }
  }

  /// calculates the scroll direction (+-) and magnitude from the previous absolute scroll position
  /// to the current absolute scroll position.
  /// Range of both current and previous should be -pi..pi
  double _scrollDistance(double current, double previous) {
    // handle negative crossover cases
    if (current >= 0.0 && previous >= 0.0) {
      return current - previous; // e.g. 3.1 - 1.5 = +1.6
    }
    else if (current <= 0.0 && previous <= 0.0) {
      return current - previous; // e.g. -2 - -1 = -1
    }
    else if (current <= 0.0 && previous >= 0.0) {
      if ((previous - current) < pi) {
        return current - previous; // e.g. -1 - 1 = -2
      }
      else {
        return 2*pi + (current - previous); // e.g. -2 - 2 = -4
      }
    }
    else if (current >= 0.0 && previous <= 0.0) {
      if ((current - previous) < pi) {
        return current - previous; // e.g. 1 - -1 = 2
      }
      else {
        return 2*pi - (current - previous); // e.g. 2 - -2 = 4
      }
    }
    return 0.0;
  }

  /// Polls the ring for a snapshot of SpO2, PPG and Accelerometer data
  Future<void> _enableRawDataPolling() async {
    if (!_pollRawDataOn) {
      _pollRawDataOn = true;
      await _sendCommand(ring.Command.getAllRawData.bytes);
    }
  }

  /// Stops polling the ring for a snapshot of SpO2, PPG and Accelerometer data
  Future<void> _disableRawDataPolling() async {
    _pollRawDataOn = false;
  }

  Future<void> _enableWaveGestureDetection() async {
    await _sendCommand(ring.Command.enableWaveGesture.bytes);
  }

  Future<void> _disableWaveGestureDetection() async {
    await _sendCommand(ring.Command.disableWaveGesture.bytes);
  }

  /// Actually send the 16-byte command message to the custom Write characteristic
  Future<void> _sendCommand(List<int> cmd) async {
    if (_device != null && _device!.isConnected && _charWrite != null) {
      try {
        await _charWrite!.write(cmd);
      }
      catch (e) {
        debugPrint(e.toString());
      }
    }
  }
}
