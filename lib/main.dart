import 'dart:async';
import 'dart:math';

import 'package:colmi_r0x_controller/colmi_r0x_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:oscilloscope/oscilloscope.dart';

void main() {
  FlutterBluePlus.setLogLevel(LogLevel.info);
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'COLMi R0x Controller Demo',
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

  int _rawX = 0;
  int _rawY = 0;
  int _rawZ = 0;
  int _accelMillis = 0;
  double _rawScrollPosition = 0.0;
  double _filteredScrollPosition = 0.0;
  double _rawNetGforce = 0.0;
  double _filteredNetGforce = 0.0;

  static const int _graphPoints = 300;
  final List<double> _rawScrollPositionList = [];
  final List<double> _filteredScrollPositionList = [];
  final List<double> _filteredNetGforceList = [];
  final List<double> _rawNetGForceList = [];
  int _taps = 0;

  _HomePageState() {
    // note: rawEventListener is not necessary, only used for realtime display of raw values in this demo
    _controller = ColmiR0xController(_stateListener, _controlEventListener, rawEventListener: _rawEventListener);
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
    if (event == ControlEvent.provisionalSelect) _taps++;

    setState(() {});
  }

  void _rawEventListener(int rawX, int rawY, int rawZ, double rawScrollPosition, double filteredScrollPosition, double rawNetGforce, double filteredNetGforce, int accelMillis) {
    _accelMillis = accelMillis;
    _rawX = rawX;
    _rawY = rawY;
    _rawZ = rawZ;

    _rawNetGforce = rawNetGforce;
    _filteredNetGforce = filteredNetGforce;

    _rawScrollPosition = rawScrollPosition;
    _filteredScrollPosition = filteredScrollPosition;

    // show the changing values on oscilloscopes
    _rawNetGForceList.add(_rawNetGforce);
    if (_rawNetGForceList.length > _graphPoints) _rawNetGForceList.removeAt(0);
    _filteredNetGforceList.add(_filteredNetGforce);
    if (_filteredNetGforceList.length > _graphPoints) _filteredNetGforceList.removeAt(0);

    _filteredScrollPositionList.add(_filteredScrollPosition);
    if (_filteredScrollPositionList.length > _graphPoints) _filteredScrollPositionList.removeAt(0);
    _rawScrollPositionList.add(_rawScrollPosition);
    if (_rawScrollPositionList.length > _graphPoints) _rawScrollPositionList.removeAt(0);

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
        title: const Text('COLMi R0x Controller Demo'),
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
              SizedBox(height: 120,
                child: Wrap(direction: Axis.vertical, runSpacing: 30.0, children: [
                Text('Accel Millis: $_accelMillis',),
                const SizedBox(height: 10),
                Text('Raw X: $_rawX',),
                const SizedBox(height: 10),
                Text('Raw Y: $_rawY',),
                const SizedBox(height: 10),
                Text('Raw Z: $_rawZ',),
                const SizedBox(height: 10),
                Text('Taps: $_taps',),
                const SizedBox(height: 10),
              ]),
            ),
            const Divider(),

            Text('Raw Scroll: ${_rawScrollPosition.toStringAsFixed(2)}',),
            SizedBox(height: 90,
            child:Oscilloscope(
              yAxisMin: -pi,
              yAxisMax: pi,
              dataSet: _rawScrollPositionList.toList(),
              backgroundColor: Colors.white,
              traceColor: Colors.black,
            )),
            const Divider(),

            Text('Raw Net g-Force: ${_rawNetGforce.toStringAsFixed(2)}',),
            SizedBox(height: 90,
            child:Oscilloscope(
              yAxisMin: 0,
              yAxisMax: 1,
              dataSet: _rawNetGForceList.toList(),
              backgroundColor: Colors.white,
              traceColor: Colors.black,
            )),
            const Divider(),

            Text('Filtered Scroll: ${_filteredScrollPosition.toStringAsFixed(2)}',),
            SizedBox(height: 90,
            child:Oscilloscope(
              yAxisMin: -pi,
              yAxisMax: pi,
              dataSet: _filteredScrollPositionList.toList(),
              backgroundColor: Colors.white,
              traceColor: Colors.black,
            )),
            const Divider(),

            Text('Filtered Net g-Force: ${_filteredNetGforce.toStringAsFixed(2)}',),
            SizedBox(height: 90,
            child:Oscilloscope(
              yAxisMin: 0,
              yAxisMax: 1,
              dataSet: _filteredNetGforceList.toList(),
              backgroundColor: Colors.white,
              traceColor: Colors.black,
            )),
          ],
        ),
      ),
    );
  }
}
