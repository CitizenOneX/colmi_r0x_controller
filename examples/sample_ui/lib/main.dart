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

/// Dummy (focusable) items for example ListView
class ListItem {
  bool isSelected = false;
  final String text;
  late final FocusNode focusNode;

  ListItem(this.text) {
    focusNode = FocusNode();
  }
}

List<ListItem> setupListData() {
  List<ListItem> list = [];
  list.add(ListItem('E. Honda'));
  list.add(ListItem('Blanka'));
  list.add(ListItem('Ryu'));
  list.add(ListItem('Ken'));
  list.add(ListItem('Zangief'));
  list.add(ListItem('Dhalsim'));
  list.add(ListItem('Guile'));
  list.add(ListItem('Chun-Li'));
  list.add(ListItem('Balrog'));
  list.add(ListItem('Vega'));
  list.add(ListItem('Sagat'));
  list.add(ListItem('M. Bison'));
  return list;
}

class _HomePageState extends State<HomePage> {

  late final ColmiR0xController _controller;
  ControllerState _controllerState = ControllerState.disconnected;
  ControlEvent _controlEvent = ControlEvent.none;

  late final List<ListItem> _list;
  int _focusItem = 0;
  String _hint = 'Wait for connection';

  final ScrollController _scrollController = ScrollController();

  _HomePageState() {
    _list = setupListData();
    _controller = ColmiR0xController(_stateListener, _controlEventListener);
    _controller.connect();
  }

  @override
  void dispose() {
    for (var f in _list) {
      f.focusNode.dispose();
    }
    _controller.disconnect();
    super.dispose();
  }

  void _stateListener(ControllerState newState) {
    debugPrint('State Listener called: $newState');

    switch (newState) {
      case ControllerState.disconnected:
        _hint = 'Click connect button to connect to ring';
        break;
      case ControllerState.scanning:
        _hint = 'Wait for scanning to find ring';
        break;
      case ControllerState.connecting:
        _hint = 'Wait for connection to ring';
        break;
      case ControllerState.idle:
        _hint = 'Wave to wake';
        break;
      case ControllerState.userInput:
        _hint = 'Scroll up or down to move focus';
        break;
      case ControllerState.verifyIntentionalWakeup:
        _hint = 'Scroll a full revolution to confirm wakeup; reverse scroll to cancel';
        break;
      case ControllerState.verifyIntentionalSelection:
        _hint = 'Scroll a full revolution to confirm selection; reverse scroll to cancel';
        break;
      default:
    }

    _controllerState = newState;
    setState(() {});
  }

  void _controlEventListener(ControlEvent event) {
    debugPrint('Control Event Listener called: $event');
    _controlEvent = event;

    switch (event) {
      case ControlEvent.confirmWakeupIntent:
        break;
      case ControlEvent.confirmSelectionIntent:
         _list[_focusItem].isSelected = !_list[_focusItem].isSelected;
        _setFocusAndScroll(_focusItem);
        break;
      case ControlEvent.scrollUp:
        _focusItem == 0 ? null : _focusItem--;
        _setFocusAndScroll(_focusItem);
        break;
      case ControlEvent.scrollDown:
        _focusItem == _list.length - 1 ? null : _focusItem++;
        _setFocusAndScroll(_focusItem);
        break;
      case ControlEvent.cancelIntent:
        break;
      default:
    }

    // TODO work out the role of the delay here
    Future.delayed(const Duration(milliseconds: 50),(){_list[_focusItem].focusNode.requestFocus();});
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

  Widget _getListItemTile(BuildContext context, int index) {
    return Focus(
      focusNode: _list[index].focusNode,
      onFocusChange: (hasFocus) { setState(() {});}, // rebuild to apply visual changes
      child: Container(
        decoration: BoxDecoration(
          border: _list[index].focusNode.hasFocus ? Border.all(color: Colors.blue, width: 2.0) : Border.all(color: Colors.white, width: 2.0),
          color: _list[index].isSelected ? Colors.red[100] : Colors.white,
        ),
        child: ListTile(
          title: Text(_list[index].text),
        )
      )
    );
  }

  void _setFocusAndScroll(int index) {
    _list[index].focusNode.requestFocus();
    _scrollController.animateTo(
      index * 25.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('COLMi R0x Controller Sample UI Demo'),
      ),
      body: Column(
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
          Text('Hint: $_hint',),
          const Divider(),

          Expanded(
            child: ListView.builder(
              itemCount: _list.length,
              itemBuilder: _getListItemTile,
              controller: _scrollController,),
          )
        ],
      ),
    );
  }
}
