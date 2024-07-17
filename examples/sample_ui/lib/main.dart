import 'dart:async';

import 'package:colmi_r0x_controller/colmi_r0x_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.info);
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'COLMi R0x Controller Sample UI Demo',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {

  late final ColmiR0xController _controller;
  ControllerState _controllerState = ControllerState.disconnected;
  ControlEvent _controlEvent = ControlEvent.none;

  int _taps = 0;
  int _scrollUps = 0;
  int _scrollDowns = 0;

  _HomePageState() {
    _controller = ColmiR0xController(_stateListener, _controlEventListener);
    _controller.connect();
  }

  void _stateListener(ControllerState newState) {
    debugPrint('State Listener called: $newState');
    _controllerState = newState;
    setState(() {});
  }

  void _controlEventListener(ControlEvent event) {
    debugPrint('Control Event Listener called: $event');
    _controlEvent = event;
    switch (event) {
      case ControlEvent.confirmIntent:
         _taps++;
        break;
      case ControlEvent.scrollUp:
        _scrollUps++;
        break;
      case ControlEvent.scrollDown:
        _scrollDowns++;
        break;
      default:
    }

    setState(() {});
  }


  /// Connect to the ring if we have previously disconnected
  Future<void> _connect() async {
    _controller.connect();
    setState(() {});
  }


  /// Disconnect from the ring and cancel the notification subscription
  Future<void> _disconnect() async {
    _controller.disconnect();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('COLMi R0x Controller Sample UI Demo'),
      ),
      body: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            const Divider(),
            ElevatedButton(
              onPressed: (_controllerState == ControllerState.disconnected) ? _connect : _disconnect,
              child: Text((_controllerState == ControllerState.disconnected) ? "Connect" : "Disconnect"),
            ),
            const Divider(),
            Text('Current State: ${_controllerState.name}',),
            Text('Last Event: ${_controlEvent.name}',),
            const Divider(),

              // accelerometer data
              SizedBox(height: 60,
                child: Wrap(direction: Axis.vertical, runSpacing: 30.0, children: [
                Text('Taps: $_taps',),
                Text('Scroll Ups: $_scrollUps',),
                Text('Scroll Downs: $_scrollDowns',),
                const SizedBox(height: 10),
              ]),
            ),
            const Divider(),
          ],
        ),
      ),
    );
  }
}
