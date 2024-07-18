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

/// Dummy items for example ListView
class ListItem {
  bool isSelected = false;
  String text;

  ListItem(this.text);
}

List<ListItem> getListData() {
  List<ListItem> list = [];
  list.add(ListItem('Death Star'));
  list.add(ListItem('Executor'));
  list.add(ListItem('Home One'));
  list.add(ListItem('Imperial Landing Craft'));
  list.add(ListItem('Imperial Shuttle'));
  list.add(ListItem('Imperial Star Destroyer'));
  list.add(ListItem('Rebel Medical Frigate'));
  list.add(ListItem('Rebel Transport'));
  list.add(ListItem('Slave I'));
  list.add(ListItem('Banking Clan Frigate'));
  list.add(ListItem('Commerce Guild Support Destroyer'));
  list.add(ListItem('Dooku\'s Solar Sailer'));
  list.add(ListItem('Invisible Hand'));
  list.add(ListItem('Naboo Royal Cruiser'));
  list.add(ListItem('Naboo Royal Starship'));
  return list;
}

class _HomePageState extends State<HomePage> {

  late final ColmiR0xController _controller;
  ControllerState _controllerState = ControllerState.disconnected;
  ControlEvent _controlEvent = ControlEvent.none;

  late final List<ListItem> _list;
  late final List<FocusNode> _focusNodeList;
  int _focusItem = 0;

  final ScrollController _scrollController = ScrollController();

  _HomePageState() {
    _list = getListData();
    _controller = ColmiR0xController(_stateListener, _controlEventListener);
    _controller.connect();
  }

  @override
  void initState() {
    super.initState();
    _focusNodeList = List.generate(_list.length, (index) => FocusNode());
  }

  @override
  void dispose() {
    for (var f in _focusNodeList) {
      f.dispose();
    }
    super.dispose();
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
      default:
    }

    Future.delayed(const Duration(milliseconds: 50),(){_focusNodeList[_focusItem].requestFocus();});
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
      focusNode: _focusNodeList[index],
      onFocusChange: (hasFocus) { setState(() {});}, // rebuild to apply visual changes
      child: Container(
        decoration: BoxDecoration(
          border: _focusNodeList[index].hasFocus ? Border.all(color: Colors.blue, width: 2.0) : Border.all(color: Colors.white, width: 2.0),
          color: _list[index].isSelected ? Colors.red[100] : Colors.white,
        ),
        child: ListTile(
          title: Text(_list[index].text),
        )
      )
    );
  }

  void _setFocusAndScroll(int index) {
    _focusNodeList[index].requestFocus();
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
