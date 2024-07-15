// COLMi R02-R06:
// - RF03 Bluetooth 5.0 LE SoC
// - STK8321 3-axis linear accelerometer
//    - 12 bits per axis, sampling rate configurable between 14Hz->2kHz
//    - motion triggered interrupt signal generation (New data, Any-motion (slope) detection, Significant motion)
// - Vcare VC30F Heart Rate Sensor
// - "Electric Type" Activity Detection (?)

/// BLE Advertised Name matches 'R0n_xxxx'
const advertisedNamePattern = r'^R0\d_[0-9A-Z]{4}$';

/// UUIDs of key custom services and characteristics on the COLMi rings
enum Uuid {
  cmdService ('6e40fff0-b5a3-f393-e0a9-e50e24dcca9e'),
  cmdWriteChar ('6e400002-b5a3-f393-e0a9-e50e24dcca9e'),
  cmdNotifyChar ('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  const Uuid(this.str128);

  final String str128;
}

/// Commands we can send to the ring
enum Command {
  enableWaveGesture (hex: '0204'),
  waitingForWaveGesture (hex: '0205'), // confirms back with 0x0200 response
  disableWaveGesture (hex: '0206'),
  getAllRawData (hex: 'a103');

  const Command({required this.hex});

  final String hex;
  List<int> get bytes => hexStringToCmdBytes(hex);
}

/// 16-byte data notifications we receive back from the ring that are all parsed with custom parsers.
enum Notification {
  waveGesture (0x02), // 0x0200 confirmation, 0x0202 wave detected
  rawSensor (0xa1);

  const Notification(this.code);

  final int code;
}

/// Subtype (second byte) of 16-byte notifications we receive from the ring
/// after making a RawSensor (0xa1) subscription
enum RawSensorSubtype {
  accelerometer (0x03);

  const RawSensorSubtype(this.code);

  final int code;
}

/// Takes a short hex command e.g. 'A102' and packs it (with a checksum) into a well-formed 16-byte command message
List<int> hexStringToCmdBytes(final String hexString) {
  if (hexString.length > 30 || hexString.length % 2 == 1) throw ArgumentError('hex string must be an even number of hex digits [0-f] less than or equal to 30 chars');
  final bytes = List<int>.filled(16, 0);
  for (int i=0; i<hexString.length/2; i++) {
    bytes[i] = int.parse(hexString.substring(2*i, 2*i+2), radix: 16);
  }
  // last byte is a checksum
  bytes[15] = bytes.fold(0, (previous, current) => previous + current) & 0xff;
  return bytes;
}

/// Returns IMU/accelerometer data
/// ±4g sensor 12-bit signed, so g value = (rawvalue/2048)*4 in g i.e. raw/512
/// Z is the axis that passes through the centre of the ring
/// Y is tangent to the ring
/// X is vertical when worn on the finger
/// e.g. [161, 3, 0, 12, 31, 6, 251, 3, 0, 0, 0, 0, 0, 0, 0, 211]
(int, int, int) parseRawAccelerometerSensorData(List<int> data) {
  assert(data.length == 16);
  assert(data[0] == 0xa1);
  assert(data[1] == 0x03);

  // raw values are a 12-bit signed value (±2048) reflecting the range ±4g
  // so 1g (gravity) shows up as ±512 in rawZ when the ring is laying flat
  // (positive or negative depending on which side is face up)
  int rawY = ((data[2] << 4) | (data[3] & 0xf)).toSigned(12);
  int rawZ = ((data[4] << 4) | (data[5] & 0xf)).toSigned(12);
  int rawX = ((data[6] << 4) | (data[7] & 0xf)).toSigned(12);

  return (rawX, rawY, rawZ);
}