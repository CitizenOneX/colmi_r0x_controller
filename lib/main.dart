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

  int? _rawX;
  int? _rawY;
  int? _rawZ;
  int? _accelMillis;
  double? _scroll;
  double? _impact;
  double? _netGforce;
  static const int _graphPoints = 300;
  final List<double> _scrollList = [];
  final List<double> _impactList = [];
  final List<double> _netGForceList = [];
  int _taps = 0;

  _HomePageState() {
    _controller = ColmiR0xController(_stateListener, _controlEventListener);
    _controller.connect();
  }

  void _stateListener(ControllerState newState) {
    debugPrint('State Listener called: $newState');
    _controllerState = newState;
    setState(() {});
  }

  void _controlEventListener(int rawX, int rawY, int rawZ, double scrollPosition, double impact, double netGforce, int accelMillis, bool isTap) {
    //debugPrint('Control Event Listener called: ');
    _rawX = rawX;
    _rawY = rawY;
    _rawZ = rawZ;
    _scroll = scrollPosition;
    _impact = impact;
    _netGforce = netGforce;
    _accelMillis = accelMillis;

    if (isTap) _taps++;

    _netGForceList.add(_netGforce!);
    if (_netGForceList.length > _graphPoints) _netGForceList.removeAt(0);
    _scrollList.add(_scroll!);
    if (_scrollList.length > _graphPoints) _scrollList.removeAt(0);
    _impactList.add(_impact!);
    if (_impactList.length > _graphPoints) _impactList.removeAt(0);

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

              // accelerometer data
              SizedBox(height: 120,
                child: Wrap(direction: Axis.vertical, runSpacing: 30.0, children: [
                Text('Accel Millis: ${_accelMillis ?? ''}',),
                const SizedBox(height: 10),
                Text('Raw X: ${_rawX ?? ''}',),
                const SizedBox(height: 10),
                Text('Raw Y: ${_rawY ?? ''}',),
                const SizedBox(height: 10),
                Text('Raw Z: ${_rawZ ?? ''}',),
                const SizedBox(height: 10),
                Text('Taps: $_taps',),
                const SizedBox(height: 10),
                Column(children: [
                  Row(children:[
                    Text('Scroll: ${_scroll?.toStringAsFixed(2) ?? ''}',),
                    Slider(value: _scroll ?? 0, min:-pi, max:pi, onChanged: (val)=>{},),
                  ]),
                  Row(children:[
                    Text('Impact: ${_impact?.toStringAsFixed(2) ?? ''}',),
                    Slider(value: _impact?.clamp(0, 1) ?? 0, min:0, max:1, onChanged: (val)=>{},),
                  ]),
                ]),
              ]),
            ),
            const Divider(),

            Text('Scroll: ${_scroll?.toStringAsFixed(2) ?? ''}',),
            SizedBox(height: 120,
            child:Oscilloscope(
              yAxisMin: -pi,
              yAxisMax: pi,
              dataSet: _scrollList.toList(),
              backgroundColor: Colors.white,
              traceColor: Colors.black,
            )),
            const Divider(),

            const Divider(),
            Text('Impact: ${_impact?.toStringAsFixed(2) ?? ''}',),
            SizedBox(height: 120,
            child:Oscilloscope(
              yAxisMin: 0,
              yAxisMax: 1,
              dataSet: _impactList.toList(),
              backgroundColor: Colors.white,
              traceColor: Colors.black,
            )),
            const Divider(),

            const Divider(),
            Text('GForce: ${_netGforce?.toStringAsFixed(2) ?? ''}',),
            SizedBox(height: 120,
            child:Oscilloscope(
              yAxisMin: 0,
              yAxisMax: 1,
              dataSet: _netGForceList.toList(),
              backgroundColor: Colors.white,
              traceColor: Colors.black,
            )),
            const Divider(),

          ],
        ),
      ),
    );
  }
}
