# colmi_r0x_controller

COLMi R02-R06 (BlueX RF03 SoC) Ring-as-Controller

_(Please note that some R02 rings may contain other SoCs and firmware and will not be compatible.)_
- Scroll and Tap to select
- Uses Flutter Blue Plus for Bluetooth LE connectivity
- Built for Android and iOS but only tested on Android
- Scroll position is surprisingly reliable, false positive and false negative taps are trickier and require more experimentation

### Example apps
![Screenshot](examples/sample_ui/docs/sample_ui.jpg)
![Screenshot](examples/raw_viewer/docs/raw_viewer.jpg)

### Demo videos
[![Raw View Example](https://img.youtube.com/vi/UPLIEYr89r4/0.jpg)](https://www.youtube.com/watch?v=UPLIEYr89r4)
[![Sample UI Example](https://img.youtube.com/vi/szf1kqJI-5I/0.jpg)](https://www.youtube.com/watch?v=szf1kqJI-5I)

### Controller Interaction Model:
 - Wave gesture to wake
 - Perform a full rotation Scroll Up to confirm Wakeup (or flip the ring around if it's scrolling down)
 - Once confirmed, ring is in the User Input state and should recognise Scroll Up, Scroll Down and (tap to) Select
 - (Taps can be missed when accelerometer is only sampled every 250ms, so tap hard and tap often. 30ms sampling should be happening on Android.)
 - Perform a full rotation Scroll Up to confirm the Select command
 - If confirmation rotation for Wakeup or Select is too slow, it times out back to Idle or User Input states respectively
 - Down scrolling while in the Verify Wakeup or Verify Selction state cancels the verification back to Idle and User Input states respectively.
