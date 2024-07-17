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
  provisionalIntent,
  verifyIntent25,
  verifyIntent50,
  verifyIntent75,
  confirmIntent,
  timeout,
}

/// Finds, connects to and sets up a Colmi R0x ring as a controller for input.
class ColmiR0xController {
  /// how much time after the tap to allow the user to start a verification scroll
  static const int intentMillisInitial = 2000;
  /// how much more time to add each time the verification passes another 25%
  static const int intentMillisExtra = 500;


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
  int _lastUpdateTime = 0;
  int _accelMillis = 0;

  // keep the previous 2 values as history for detecting taps and scrolls
  // [0] has the older value, [1] is the newer
  final _rawX = [0, 0];
  final _rawY = [0, 0];
  final _rawZ = [0, 0];
  final _rawNetGforce = [0.0, 0.0];
  final _filteredNetGForce = [0.0, 0.0];
  final _filteredNetOrthoForce = [0.0, 0.0];
  final _rawScrollPosition = [0.0, 0.0];
  final _filteredScrollPosition = [0.0, 0.0];
  final _filteredScrollPositionDiff = [0.0, 0.0]; // filtered, rectified difference between samples
  // set an initial gravity estimate vector
  int _gX = 512;
  int _gY = 0;
  int _gZ = 0;
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

    switch (newState) {
      case ControllerState.idle:
        _enableWaveGestureDetection();
        break;

      case ControllerState.userInput:
        if (_currentState == ControllerState.verifyIntentionalWakeup) {
          _disableWaveGestureDetection();
          _enableRawDataPolling();
        }
        // if coming from an aborted verifyIntentionalSelection then no need
        // to change wave gesture detection or raw data polling
        break;

      case ControllerState.disconnected:
        _disableRawDataPolling();
        break;

      case ControllerState.verifyIntentionalSelection:
        _verifyStartPos = _currentAbsPos;
        _verifyStartTime = DateTime.timestamp().millisecondsSinceEpoch;
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
    // TODO do we want to guarantee sending events first or new state first?
    _stateListener.call(newState);
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
        // if it's been more than 2 seconds since our last sample, then treat this
        // as a new interaction so we can't refer to prior scroll position or forces
        bool firstSample = (_accelMillis > 2000);

        // pull the raw values out of the bluetooth message payload
        var (rawX, rawY, rawZ) = ring.parseRawAccelerometerSensorData(data);

        // calculate the magnitude of the acceleration overall, net of gravity, in g
        var rawNetGforce = (sqrt(rawX * rawX + rawY * rawY + rawZ * rawZ)/512.0 - 1.0).abs();
        var filteredNetGForce = 0.0;
        var filteredNetOrthoForce = 0.0;

        // for tracking the scroll position
        var rawScrollPosition = 0.0;
        var filteredScrollPosition = 0.0;
        var filteredScrollPositionDiff = 0.0;

        // if the magnitude of the g-forces is very close to 1 (within 5%)
        // or if it's the first sample (no other choice)
        // then update our gravity vector
        // TODO maybe even more so if the last sample was also close to 1 and similar in x,y,z to this one?
        if (rawNetGforce < 0.05 || firstSample) {
          _gX = rawX;
          _gY = rawY;
          _gZ = rawZ;
          //debugPrint('updated g: [$_gX, $_gY, $_gZ] ${sqrt(_gX*_gX + _gY*_gY + _gZ*_gZ)/512.0}');
        }

        if (firstSample) {
          debugPrint('First sample: rawNetGforce=$rawNetGforce, scrollPosition=${atan2(rawY, rawX)}');
        }

        if (_currentState == ControllerState.userInput) {
          // if we're pretty close to g, then the ring is at rest or perhaps gentle scrolling
          // but not a tap, so scroll position can still be interpreted
          // first sample we don't really have a choice
          if (rawNetGforce < 0.1 || firstSample) {
            // calculate absolute "scroll" position when rotated around the finger
            // (the finger matches the Z axis)
            // range -pi .. pi
            rawScrollPosition = atan2(rawY, rawX);
            filteredScrollPosition = rawScrollPosition;
            filteredScrollPositionDiff = firstSample ? 0.0 : _calcScrollDistance(rawScrollPosition, _filteredScrollPosition[1]);
            // keep filteredNetGforce and filteredNetOrthoForce at 0.0
          }
          else if (rawNetGforce > 0.15) {
            // if values are large, this might be a flick or tap,
            // so scroll position will be unreliable so copy the previous scroll position
            rawScrollPosition = _rawScrollPosition[1];
            filteredScrollPosition = _filteredScrollPosition[1];

            // range > 0, in g
            filteredNetGForce = rawNetGforce;
            // work out net tap/flick direction
            var xNetForce = rawX - _gX;
            var yNetForce = rawY - _gY;
            var zNetForce = rawZ - _gZ;
            debugPrint('updated net force: [$xNetForce, $yNetForce, $zNetForce] ${sqrt(xNetForce*xNetForce + yNetForce*yNetForce + zNetForce*zNetForce)/512.0}');

            // dot that force vector with our gravity vector to see how much of the force
            // is in the gravity direction
            var forceParallelToGravity = (xNetForce * _gX + yNetForce * _gY + zNetForce * _gZ)/(512*512);

            // subtract out the portion of the force in the gravity direction to get the force
            // in the plane orthogonal to gravity
            var xOrthG = rawX - forceParallelToGravity*_gX;
            var yOrthG = rawY - forceParallelToGravity*_gY;
            var zOrthG = rawZ - forceParallelToGravity*_gZ;

            filteredNetOrthoForce = sqrt(xOrthG*xOrthG + yOrthG*yOrthG + zOrthG*zOrthG)/512;
            debugPrint('forceParallelToGravity: $forceParallelToGravity, filteredNetOrthoForce: $filteredNetOrthoForce');
          }
          else {
            // ambiguous zone, just report the previous value for scroll position
            // and zero for everything else
            rawScrollPosition = _rawScrollPosition[1];
            filteredScrollPosition = _filteredScrollPosition[1];
          }
        }
        else if (_currentState == ControllerState.verifyIntentionalSelection || _currentState == ControllerState.verifyIntentionalWakeup) {
          // just track scrolling, don't worry about detecting taps
          // calculate absolute "scroll" position when rotated around the finger
          // (the finger matches the Z axis)
          // range -pi .. pi
          rawScrollPosition = atan2(rawY, rawX);
          filteredScrollPosition = rawScrollPosition;
          filteredScrollPositionDiff = firstSample ? 0.0 : _calcScrollDistance(rawScrollPosition, _filteredScrollPosition[1]);
          // keep filteredNetGforce and filteredNetOrthoForce at 0.0
        }

        // absolute position accumulates the diffs so its range can exceed +-pi
        // because it's necessary to detect when a half revolution has happened
        _currentAbsPos += filteredScrollPositionDiff;

        // update the listeners with the latest values
        // raw, only if subscribed
        _rawEventListener?.call(rawX, rawY, rawZ, rawScrollPosition, filteredScrollPosition, filteredScrollPositionDiff, rawNetGforce, filteredNetGForce, filteredNetOrthoForce, _accelMillis);

        // control events: taps and scrolls, and tap confirmations (half revolution after provisional tap)
        switch (_currentState) {
          case ControllerState.userInput:

            // work out if we have taps, scrolls or neither
            // TODO debounce by tracking the last few events and
            // only send a tap or scroll if the last couple of messages (or time interval?) were not

            // we say it's a tap if it's large g-force that lasts for only one sample
            // mostly in the plane orthogonal to gravity
            // and not if the last few scroll samples showed significant movement
            // TODO is the orthogonal force really adding anything here compared with GForce?
            var isTap = (_filteredNetGForce[0] == 0.0) && (_filteredNetOrthoForce[1] > 0.40) && (filteredNetGForce == 0.0)
              && (filteredScrollPositionDiff < 0.15) && (_filteredScrollPositionDiff[1] < 0.15);

            // generate scroll events if the net gforce is low (clipped to zero)
            // and there has been significant movement in the absolute scroll position
            // TODO since the last update, or since the last stable measurement?
            var isScrollUp = (filteredNetGForce == 0.0) && (filteredScrollPositionDiff > 0.5);
            var isScrollDown = (filteredNetGForce == 0.0) && (filteredScrollPositionDiff < -0.5);

            if (isTap) {
              // taps are only valid provisional selections when in userInput mode
              _controlEventListener.call(ControlEvent.provisionalIntent);
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
            if (receivedTime - _verifyStartTime > ColmiR0xController.intentMillisInitial) {
              _pollRawDataOn = false;
              _controlEventListener.call(ControlEvent.timeout);
              _transitionTo(ControllerState.idle);
              break;
            }
            var isScrollUp = (filteredNetGForce == 0.0) && (filteredScrollPositionDiff > 0.5);
            if (isScrollUp) {
              if (_currentAbsPos >= _verifyStartPos + 2*pi) {
                debugPrint('Wakeup intent verified');
                // finished verifying
                _controlEventListener.call(ControlEvent.confirmIntent);
                _transitionTo(ControllerState.userInput);
              }
              else if (_currentAbsPos >= _verifyStartPos + (3*pi)/2) {
                _controlEventListener.call(ControlEvent.verifyIntent75);
                _verifyStartTime += ColmiR0xController.intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi) {
                _controlEventListener.call(ControlEvent.verifyIntent50);
                _verifyStartTime += ColmiR0xController.intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi/2) {
                _controlEventListener.call(ControlEvent.verifyIntent25);
                _verifyStartTime += ColmiR0xController.intentMillisExtra;
              }
            }
            break;

          case ControllerState.verifyIntentionalSelection:
            // if our timeout for confirmation has expired, transition back to userInput
            if (DateTime.timestamp().millisecondsSinceEpoch - _verifyStartTime > ColmiR0xController.intentMillisInitial) {
              _controlEventListener.call(ControlEvent.timeout);
              _transitionTo(ControllerState.userInput);
              break;
            }
            var isScrollUp = (filteredNetGForce == 0.0) && (filteredScrollPositionDiff > 0.5);
            if (isScrollUp) {
              if (_currentAbsPos >= _verifyStartPos + 2*pi) {
                // finished verifying the selection, back to idle
                debugPrint('Selection intent verified');
                _pollRawDataOn = false;
                _controlEventListener.call(ControlEvent.confirmIntent);
                _transitionTo(ControllerState.idle);
              }
              else if (_currentAbsPos >= _verifyStartPos + (3*pi)/2) {
                _controlEventListener.call(ControlEvent.verifyIntent75);
                _verifyStartTime += ColmiR0xController.intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi) {
                _controlEventListener.call(ControlEvent.verifyIntent50);
                _verifyStartTime += ColmiR0xController.intentMillisExtra;
              }
              else if (_currentAbsPos >= _verifyStartPos + pi/2) {
                _controlEventListener.call(ControlEvent.verifyIntent25);
                _verifyStartTime += ColmiR0xController.intentMillisExtra;
              }
              break;
            }

            default:
        }

        // kick off the next request
        if (_pollRawDataOn) {
          _sendCommand(ring.Command.getAllRawData.bytes);
        }

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

        _filteredNetGForce[0] = _filteredNetGForce[1];
        _filteredNetGForce[1] = filteredNetGForce;

        _filteredNetOrthoForce[0] = _filteredNetOrthoForce[1];
        _filteredNetOrthoForce[1] = filteredNetOrthoForce;

        _filteredScrollPosition[0] = _filteredScrollPosition[1];
        _filteredScrollPosition[1] = filteredScrollPosition;

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
