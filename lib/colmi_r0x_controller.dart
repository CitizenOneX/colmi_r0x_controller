import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'colmi_ring.dart' as ring;

enum ControllerState {
  scanning,
  connecting,
  connected, // connected but not raw polling or awaiting shake gesture
  idle, // shake to wake, not raw polling
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
  provisionalWakeupIntent,
  provisionalSelectionIntent,
  verifyIntent25,
  verifyIntent50,
  verifyIntent75,
  cancelIntent,
  confirmWakeupIntent,
  confirmSelectionIntent,
  timeout,
}

/// Finds, connects to and sets up a Colmi R0x ring as a controller for input.
class ColmiR0xController {
  /// how much time after the tap to allow the user to start a verification scroll
  static const int intentMillisInitial = 2000;
  /// how much more time to add each time the verification passes another 25%
  static const int intentMillisExtra = 500;
  /// angular velocity in radians per second to generate a scroll up or down event (should be positive)
  static const double scrollEventThreshold = 5;
  /// reverse scroll absolute angle in radians to generate a cancel event during verify stage (threshold value should be positive)
  static const double scrollCancelThreshold = pi/4;


  StreamSubscription<List<ScanResult>>? _scanResultSubs; // device scan subscription
  StreamSubscription<List<int>>? _charNotifySubs; // custom notify stream subscription
  StreamSubscription<BluetoothConnectionState>? _connStateSubs; // device connection state subscription

  BluetoothDevice? _device;
  BluetoothCharacteristic? _charWrite; // custom write
  BluetoothCharacteristic? _charNotify; // custom notify

  ControllerState _currentState = ControllerState.disconnected;
  final Function _stateListener;
  final Function _controlEventListener;
  final Function? _rawEventListener;

  bool _pollRawDataOn = false;
  bool _sentPriorityRequest = false;
  int _connectTime = 0;
  int _lastUpdateTime = 0;
  int _accelMillis = 0;
  int _sampleNumber = -1;

  // keep the previous 2 values as history for detecting taps and scrolls
  // [0] has the older value, [1] is the newer
  double _filteredScrollPositionPrev = 0.0;
  final _filteredScrollPositionDiff = [0.0, 0.0]; // filtered, rectified difference between samples
  final _filteredNetGForce = [0.0, 0.0];

  // track current position and time for verify procedure (full rotation within a certain time)
  double _currentAbsPos = 0.0;
  double _verifyStartPos = 0.0;
  int _verifyStartTime = 0;

  /// Take StateListener and ControlEventListener callback functions, optionally a rawEventListener
  ColmiR0xController(this._stateListener, this._controlEventListener, {Function? rawEventListener}) : _rawEventListener = rawEventListener;

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
    _sentPriorityRequest = false;
    _connectTime = 0;
    _transitionTo(ControllerState.disconnected);
  }

  /// Private method for reconnecting to a known device
  Future<void> _reconnect() async {
    try {
      if (Platform.isAndroid) {
        await _device!.connect(mtu: 24); // ring messages are only 16-bytes + BLE headers
        await _device!.setPreferredPhy(txPhy: Phy.le2m.mask, rxPhy: Phy.le2m.mask, option: PhyCoding.noPreferred);
      }
      else {
        await _device!.connect();
      }

      await _discoverServices();
      // record the moment of connection because in 5s we need to send a connection priority request
      _connectTime = DateTime.timestamp().millisecondsSinceEpoch;
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

    switch (newState) {
      case ControllerState.connected:
        // nothing to do, wait for app to ask for transition to idle or userInput
        break;

      case ControllerState.idle:
        _enableWaveGestureDetection();
        break;

      case ControllerState.userInput:
        // if coming from a successful verifyIntentionalWakeup then no need
        // to change wave gesture detection or raw data polling
        // if coming from an aborted verifyIntentionalSelection then no need
        // to change wave gesture detection or raw data polling
        // but it doesn't hurt to reaffirm the connection priority
        _enableRawDataPolling();
        break;

      case ControllerState.disconnected:
        _disableRawDataPolling();
        break;

      case ControllerState.verifyIntentionalSelection:
        _verifyStartPos = _currentAbsPos;
        _verifyStartTime = DateTime.timestamp().millisecondsSinceEpoch;
        // coming from userInput state, so raw polling is on already,
        // but it doesn't hurt to reaffirm the connection priority
        _enableRawDataPolling();
        break;

      case ControllerState.verifyIntentionalWakeup:
        _verifyStartPos = _currentAbsPos;
        _verifyStartTime = DateTime.timestamp().millisecondsSinceEpoch;
        _disableWaveGestureDetection();
        _enableRawDataPolling();
        break;
      default:
    }

    _currentState = newState;
    // send events first, and the new state at the end
    _stateListener.call(newState);
  }

  /// Callback for handling all 16-byte data notifications from the custom notification characteristic
  /// We only process raw accelerometer and wave gesture messages and ignore any others
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
        // if it's been more than 2 seconds since our last sample, then treat this
        // as a new interaction so we can't refer to prior scroll position or forces
        (_accelMillis > 2000 || _sampleNumber < 0) ? _sampleNumber = 0 : _sampleNumber++;

        if (Platform.isAndroid ) {
          // connection priority requests earlier than 5 seconds don't appear to stick
          // so send one here after 5 seconds
          if (!_sentPriorityRequest && (receivedTime - _connectTime > 5000) && _device != null && _device!.isConnected) {
            _device!.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
            _sentPriorityRequest = true;
          }
        }

        // pull the raw values out of the bluetooth message payload
        var (rawX, rawY, rawZ) = ring.parseRawAccelerometerSensorData(data);

        // calculate the magnitude of the acceleration overall, net of gravity, in g
        var rawNetGforce = (sqrt(rawX * rawX + rawY * rawY + rawZ * rawZ)/512.0 - 1.0).abs();
        var filteredNetGForce = 0.0;

        // for tracking the scroll position
        var rawScrollPosition = 0.0;
        var filteredScrollPosition = 0.0;
        var filteredScrollPositionDiff = 0.0;

        // for tracking gestures
        bool isTap = false;
        bool isScrollUp = false;
        bool isScrollDown = false;

        // now process the gesture based on the current state
        switch (_currentState) {
          case ControllerState.userInput:
            // first two samples we don't really have a choice but to calculate scroll position
            // and filtered g force
            if (_sampleNumber < 2) {
              //debugPrint('Sample $_sampleNumber: rawNetGforce=$rawNetGforce, scrollPosition=${atan2(rawY, rawX)}');
              // calculate absolute "scroll" position when rotated around the finger
              // (the finger matches the Z axis)
              // range -pi .. pi
              rawScrollPosition = atan2(rawY, rawX);
              filteredScrollPosition = rawScrollPosition;
              _currentAbsPos = rawScrollPosition;
              filteredNetGForce = rawNetGforce < 0.50 ? 0.0 : rawNetGforce;

              if (_sampleNumber == 0) {
                filteredScrollPositionDiff = 0.0;
                // also "zero" out the prior
              }
              else {
                filteredScrollPositionDiff = _calcScrollDistance(rawScrollPosition, _filteredScrollPositionPrev);
              }
            }
            // if the force is pretty close to g, then the ring is at rest or perhaps gentle scrolling
            // but not a tap, so scroll position can still be interpreted
            else if (rawNetGforce < 0.50) {
              // filter all small g forces out to zero
              filteredNetGForce = 0.0;

              // still calculate absolute "scroll" position when rotated around the finger
              // (the finger matches the Z axis)
              // range -pi .. pi
              rawScrollPosition = atan2(rawY, rawX);
              filteredScrollPosition = rawScrollPosition;
              _currentAbsPos = rawScrollPosition;
              filteredScrollPositionDiff = _calcScrollDistance(rawScrollPosition, _filteredScrollPositionPrev);

              // we say it's a tap if:
              // - it's a crazy large force (3.0+, never should happen just scrolling, only taps or waves)
              // - it's large g-force (1.25) that lasts for only one sample i.e. _/\_
              // - valid ranges of calculated scroll diffs are so large in taps that we seem to be unable to filter
              //   out occasional rough scrolls by putting constraints on scroll diff amounts here
              isTap = (_filteredNetGForce[1] > 3.0) ||
                      ((_filteredNetGForce[0] == 0.0) && (_filteredNetGForce[1] > 1.25) && (filteredNetGForce == 0.0));

              //if (_filteredNetGForce[1] > 0.20) {
              //  debugPrint('Sample $_sampleNumber: rawNetGforce=$rawNetGforce, gf-1=${_filteredNetGForce[1]}, gf-2=${_filteredNetGForce[0]}, rawScrollPrev=$_rawScrollPositionPrev, rawScroll=$rawScrollPosition, isTap=$isTap');
              //}

              if (!isTap) {
                // generate scroll events if the net gforce is low (clipped to zero)
                // and there has been significant movement in the absolute scroll position
                // adjust for speed of polling; "significant movement" needs to be an angular rate, not an absolute amount
                // We clamp to a max/min because if accelMillis are really fast, the threshold becomes very small and twitchy
                // so we also threshold it with an absolute amount that any scroll must exceed
                isScrollUp = (filteredScrollPositionDiff > max((scrollEventThreshold * (_accelMillis / 1000)), 0.4));
                isScrollDown = (filteredScrollPositionDiff < min((-scrollEventThreshold * (_accelMillis / 1000)), -0.4));
              }
            }
            else if (rawNetGforce > 1.25) {
              // if values are large, this might be a flick or tap,
              // so scroll position will be unreliable, so copy the previous filtered scroll position
              // and don't change _currentAbsPos
              // and leave _filteredScrollPositionDiff at 0.0
              rawScrollPosition = atan2(rawY, rawX);
              filteredScrollPosition = _filteredScrollPositionPrev;
              filteredScrollPositionDiff = 0.0;

              // range > 0, in g
              filteredNetGForce = rawNetGforce;
              //debugPrint('Sample $_sampleNumber: rawNetGforce=$rawNetGforce, gf-1=${_filteredNetGForce[1]}, gf-2=${_filteredNetGForce[0]}, rawScrollPrev=$_rawScrollPositionPrev, rawScroll=$rawScrollPosition');
            }
            else {
              // ambiguous zone (0.5 -> 1.25 at the moment), just report the previous value for filtered scroll position
              // and zero for everything else
              // So no tap events, no scroll events
              rawScrollPosition = atan2(rawY, rawX);
              filteredScrollPosition = _filteredScrollPositionPrev;
              //debugPrint('Sample $_sampleNumber: rawNetGforce=$rawNetGforce, gf-1=${_filteredNetGForce[1]}, gf-2=${_filteredNetGForce[0]}, rawScrollPrev=$_rawScrollPositionPrev, rawScroll=$rawScrollPosition');
            }
            break;

          case ControllerState.verifyIntentionalSelection:
          case ControllerState.verifyIntentionalWakeup:
            // just track scrolling, don't worry about detecting taps
            // calculate absolute "scroll" position when rotated around the finger
            // (the finger matches the Z axis)
            // range -pi .. pi
            rawScrollPosition = atan2(rawY, rawX);
            filteredScrollPosition = rawScrollPosition;
            filteredScrollPositionDiff = _sampleNumber == 0 ? 0.0 : _calcScrollDistance(rawScrollPosition, _filteredScrollPositionPrev);
            // keep filteredNetGforce and filteredNetOrthoForce at 0.0

            // absolute position accumulates the diffs so its range can exceed +-pi
            // because it's necessary to detect when a revolution has happened
            _currentAbsPos += filteredScrollPositionDiff;
            break;

          default:
        }

        // update the raw event listener with the latest values (if subscribed)
        _rawEventListener?.call(rawX, rawY, rawZ, rawScrollPosition, filteredScrollPosition, filteredScrollPositionDiff, rawNetGforce, filteredNetGForce, isTap, _accelMillis);

        // control events: taps and scrolls, and tap confirmations (half revolution after provisional tap)
        switch (_currentState) {
          case ControllerState.userInput:
            if (isTap) {
              // taps are only valid provisional selections when in userInput mode
              _controlEventListener.call(ControlEvent.provisionalSelectionIntent);
              _transitionTo(ControllerState.verifyIntentionalSelection);
            }
            else if (isScrollUp) {
              _controlEventListener.call(ControlEvent.scrollUp);
            }
            else if (isScrollDown) {
              _controlEventListener.call(ControlEvent.scrollDown);
            }
            break;

          case ControllerState.verifyIntentionalWakeup:
            // if our timeout for confirmation has expired, transition back to idle
            if (receivedTime - _verifyStartTime > intentMillisInitial) {
              _pollRawDataOn = false;
              _controlEventListener.call(ControlEvent.timeout);
              _transitionTo(ControllerState.idle);
              break;
            }
            var isScrollUp = (filteredNetGForce == 0.0) && (filteredScrollPositionDiff > (scrollEventThreshold * (_accelMillis / 1000)));
            if (isScrollUp) {
              if (_currentAbsPos >= _verifyStartPos + 2*pi) {
                _controlEventListener.call(ControlEvent.confirmWakeupIntent);
                _transitionTo(ControllerState.userInput);
              }
              else if (_currentAbsPos >= _verifyStartPos + (3*pi)/2) {
                _controlEventListener.call(ControlEvent.verifyIntent75);
                _verifyStartTime += intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi) {
                _controlEventListener.call(ControlEvent.verifyIntent50);
                _verifyStartTime += intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi/2) {
                _controlEventListener.call(ControlEvent.verifyIntent25);
                _verifyStartTime += intentMillisExtra;
              }
            }
            else if (_currentAbsPos < _verifyStartPos - scrollCancelThreshold) {
              // down scroll is a cancel when verifying; back to Idle
              _pollRawDataOn = false;
              _controlEventListener.call(ControlEvent.cancelIntent);
              _transitionTo(ControllerState.idle);
            }

            break;

          case ControllerState.verifyIntentionalSelection:
            // if our timeout for confirmation has expired, transition back to userInput
            if (DateTime.timestamp().millisecondsSinceEpoch - _verifyStartTime > intentMillisInitial) {
              _controlEventListener.call(ControlEvent.timeout);
              _transitionTo(ControllerState.userInput);
              break;
            }
            var isScrollUp = (filteredNetGForce == 0.0) && (filteredScrollPositionDiff > (scrollEventThreshold * (_accelMillis / 1000)));
            if (isScrollUp) {
              if (_currentAbsPos >= _verifyStartPos + 2*pi) {
                _pollRawDataOn = false;
                _controlEventListener.call(ControlEvent.confirmSelectionIntent);
                _transitionTo(ControllerState.idle);
                // TODO alternatively go to userInput if caller wants multiple selections
              }
              else if (_currentAbsPos >= _verifyStartPos + (3*pi)/2) {
                _controlEventListener.call(ControlEvent.verifyIntent75);
                _verifyStartTime += intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi) {
                _controlEventListener.call(ControlEvent.verifyIntent50);
                _verifyStartTime += intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi/2) {
                _controlEventListener.call(ControlEvent.verifyIntent25);
                _verifyStartTime += intentMillisExtra;
              }
              break;
            }
            else if (_currentAbsPos < _verifyStartPos - scrollCancelThreshold) {
              // down scroll is a cancel when verifying; back to userInput
              _controlEventListener.call(ControlEvent.cancelIntent);
              _transitionTo(ControllerState.userInput);
            }

            default:
        }

        // kick off the next request
        if (_pollRawDataOn) {
          _sendCommand(ring.Command.getAllRawData.bytes);
        }

        // update previous values
        // if the current and the n-1 g-force samples have exactly the same (non-zero) values,
        // coalesce them here to make the _/\_ spike detection easier
        // in cases where we sample the accelerometer so frequently we see the exact same value
        if (_filteredNetGForce[1] == 0 || filteredNetGForce != _filteredNetGForce[1]) {
          _filteredNetGForce[0] = _filteredNetGForce[1];
          _filteredNetGForce[1] = filteredNetGForce;
        }
        _filteredNetGForce[1] = filteredNetGForce;

        _filteredScrollPositionPrev = filteredScrollPosition;
        _filteredScrollPositionDiff[0] = _filteredScrollPositionDiff[1];
        _filteredScrollPositionDiff[1] = filteredScrollPositionDiff;
      }
    }
    // process wave gesture updates
    else if (data[0] == ring.Notification.waveGesture.code) {
      if (data[1] == 2) {
        if (_currentState == ControllerState.idle) {
          _transitionTo(ControllerState.verifyIntentionalWakeup);
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
  double _calcScrollDistance(double current, double previous) {
    // handle negative crossover cases
    if (current >= 0.0 && previous >= 0.0) {
      return current - previous; // e.g. 3.1 - 1.5 = +1.6; 1.5 - 3.1 = -1.6
    }
    else if (current <= 0.0 && previous <= 0.0) {
      return current - previous; // e.g. -2 - -1 = -1; -1 - -2 = 1;
    }
    else if (current <= 0.0 && previous >= 0.0) {
      if ((previous - current) < pi) {
        return current - previous; // e.g. -1 - 1 = -2
      }
      else {
        return 2*pi + (current - previous); // e.g. 2pi + (-2 - 2) = 2pi-4
      }
    }
    else if (current >= 0.0 && previous <= 0.0) {
      if ((current - previous) < pi) {
        return current - previous; // e.g. 1 - -1 = 2
      }
      else {
        return (current - previous) - 2*pi; // e.g. (2 - -2)-2pi = 4-2pi
      }
    }
    return 0.0;
  }

  /// Polls the ring for a snapshot of SpO2, PPG and Accelerometer data
  Future<void> _enableRawDataPolling() async {
    // requesting high priority each time we're tracking scrolling reduces the latency to ~30ms
    if (Platform.isAndroid && _device != null && _device!.isConnected) {
      await _device!.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.high);
    }

    if (!_pollRawDataOn) {
      _pollRawDataOn = true;

      await _sendCommand(ring.Command.getAllRawData.bytes);
    }
  }

  /// Stops polling the ring for a snapshot of SpO2, PPG and Accelerometer data
  Future<void> _disableRawDataPolling() async {
    _pollRawDataOn = false;

    // requesting balanced priority when not polling quickly for updates
    if (Platform.isAndroid && _device != null && _device!.isConnected) {
      await _device!.requestConnectionPriority(connectionPriorityRequest: ConnectionPriority.balanced);
    }
  }

  Future<void> _enableWaveGestureDetection() async {
    // TODO If the ring is on charge this call fails, we could check what/if it returns in case we need to do it again
    // (disconnect then reconnect when off the charger works)
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
