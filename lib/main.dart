import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
// import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';

// final WALL_SERVICE_ID = Uuid.parse('5c8468d0-024e-4a0c-a2f1-4742299119e3');
// final WALL_CHARACTERISTIC_ID = Uuid.parse('82155e2a-76a2-42fb-8273-ea01aa87c5be');

final WALL_SERVICE_ID = '5c8468d0-024e-4a0c-a2f1-4742299119e3';
final WALL_CHARACTERISTIC_ID = '82155e2a-76a2-42fb-8273-ea01aa87c5be';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isLoadingWebview = true;
  late final WebViewController _webview;
  // final FlutterReactiveBle _ble = FlutterReactiveBle();
  // late final QualifiedCharacteristic characteristic;
  // late final StreamSubscription<ConnectionStateUpdate> _btConnectionStream;
  late BluetoothDevice btDevice;
  late StreamSubscription deviceStateSubscription;
  late BluetoothCharacteristic btCharacteristic;
  late String lastBtMessage;
  bool _btConnected = false;

  @override
  void initState() {
    super.initState();

    _webview = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // ..setUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36')
      ..enableZoom(false)
      ..setBackgroundColor(Colors.black)
      // ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            debugPrint("Page started loading: $url");
          },
          onProgress: (int progress) {
            debugPrint("Loading: $progress%");
          },
          onPageFinished: (String url) {
            debugPrint("Page finished loading: $url");
            setState(() {
              _isLoadingWebview = false;
            });
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint("WebView error: ${error.description}");
          },
          onUrlChange: (UrlChange urlChange) {
            debugPrint("Url changed: ${urlChange.url}");
          }
        ),
      )
      ..addJavaScriptChannel(
        'FlutterChannel',
        onMessageReceived: (JavaScriptMessage message) async {
          debugPrint("Received from WebView: ${message.message}");
          final msg = json.decode(message.message);
          final type = msg["type"];
          final value = msg["value"];
          if (type == "GOOGLE_SIGN_IN") {
            _signInWithGoogle();
          } else if (type == "EXIT_APP") {
            if (Platform.isAndroid) {
              SystemNavigator.pop();
            } else if (Platform.isIOS) {
              exit(0);
            }
          } else if (type == "CONNECT_TO_BLUETOOTH") {
            if (await requestBluetoothPermission()) {
              _connectToBoardBluetooth();
            }
          } else if (type == "DISCONNECT_FROM_BLUETOOTH") {
            _disconnectFromBoardBluetooth();
          } else if (type == "SEND_BLUETOOTH_MESSAGE") {
            _sendMessageToBoardBluetooth(value);
          }
        },
      )
      // ..loadRequest(Uri.parse('http://192.168.0.166:8080'));
      ..loadRequest(Uri.parse('http://flashboard.site'));

    _allowCookies();
    _requestReadFilesPermission();
    _addFileSelectionListener();
  }

  Future<void> _requestReadFilesPermission() async {
    if (await Permission.photos.isRestricted) {
      await Permission.photos.request();
    } else {
      await Permission.storage.request();
    }
  }

  Future<List<String>> _androidFilePicker(FileSelectorParams params) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      return [file.uri.toString()];
    }
    return [];
  }

  void _addFileSelectionListener() async {
    if (Platform.isAndroid) {
      final androidController = _webview.platform as AndroidWebViewController;
      await androidController.setOnShowFileSelector(_androidFilePicker);
    }
  }

  Future<bool> requestBluetoothPermission() async {
    PermissionStatus bluetoothStatus = await Permission.bluetoothScan.request();
    PermissionStatus locationStatus = await Permission.location.request();

    return bluetoothStatus.isGranted && locationStatus.isGranted;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            scaffoldBackgroundColor: const Color(0x00000000)
        ),
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            _webview.runJavaScript('window.FlutterMessages.backNavigation()');
            return;
          },
          child: Scaffold(
            resizeToAvoidBottomInset: false,

            body: SafeArea(
              // child: WebViewWidget(controller: _webview, backgroundColor: Colors.black),
              child: Stack(
                children: [
                  WebViewWidget(controller: _webview),
                  if (_isLoadingWebview)
                    Container(
                      color: Colors.black, // Background color while loading
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            ),
            bottomNavigationBar: SafeArea(
              child: SizedBox(
                height: 0, // Standard BottomNavigationBar height
              ),
            ),
          ),
        )
    );
  }

  void _allowCookies() {
    PlatformWebViewCookieManagerCreationParams params = const PlatformWebViewCookieManagerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      // TODO: IOS cookie code? or will it just work magically
    } else if (WebViewPlatform.instance is AndroidWebViewPlatform) {
      params = AndroidWebViewCookieManagerCreationParams.fromPlatformWebViewCookieManagerCreationParams(params);
      final cookieManager = AndroidWebViewCookieManager(params);
      AndroidWebViewController androidController = _webview.platform as AndroidWebViewController;
      cookieManager.setAcceptThirdPartyCookies(androidController, true);

    }
  }

  void _signInWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn(
        // serverClientId: "798008696513-sqcbp664mbt6ton62f8b4e9uq4m38mjt.apps.googleusercontent.com"
        // TODO: different serverClientId for IOS!?
      ).signIn();

      if (googleUser == null) {
        // The user canceled the sign-in
        return;
      }

      debugPrint("Got user info for ${googleUser.email}");
      _webview.runJavaScript('window.FlutterMessages.signInWithGoogle("${googleUser.id}", "${googleUser.email}", "${googleUser.id}", "${googleUser.displayName}", "${googleUser.photoUrl}")');
    } catch (e) {
      debugPrint('Error during Google Sign-In: $e');
      showAlertDialog("Google Login", "Google login failed, please contact davidgdalevich7@gmail.com", "ok");
    }
  }

  showAlertDialog(title, content, buttonText) {
    final context = navigatorKey.currentContext;
    if (context == null) {
      return;
    }

    // show the dialog
    showDialog(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            child: Text(buttonText),
            onPressed: () {
              navigatorKey.currentState?.pop();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _connectToBoardBluetooth() async {
    // listen to scan results
    // Note: `onScanResults` clears the results between scans. You should use
    //  `scanResults` if you want the current scan results *or* the results from the previous scan.
    var subscription = FlutterBluePlus.onScanResults.listen((results) async {
      if (results.isNotEmpty) {
        ScanResult r = results.last; // the most recently found device
        debugPrint('Device found: ${r.device.remoteId}: "${r.advertisementData.advName}"');
        await _connectToBtDevice(r.device);
      }
    },
      onError: (e) => debugPrint("BT scanning onScanResults error: $e"),
    );

    // cleanup: cancel subscription when scanning stops
    FlutterBluePlus.cancelWhenScanComplete(subscription);

    // Wait for Bluetooth enabled & permission granted
    FlutterBluePlus.adapterState.listen((event) {
      debugPrint("BT adapter state event happened: ${event.name}");
    });

    // In your real app you should use `FlutterBluePlus.adapterState.listen` to handle all states
    await FlutterBluePlus.adapterState.where((val) => val == BluetoothAdapterState.on).first;

    // Start scanning w/ timeout
    // Optional: use `stopScan()` as an alternative to timeout
    await FlutterBluePlus.startScan(
        withServices:[Guid(WALL_SERVICE_ID)], // match any of the specified services
        timeout: Duration(seconds: 3)
    );

    // wait for scanning to stop
    await FlutterBluePlus.isScanning.where((val) => val == false).first;
    debugPrint("Finished scanning");
    if (FlutterBluePlus.connectedDevices.isEmpty) {
      _webview.runJavaScript('window.FlutterMessages.onBtConnectionResult(null)');
    }
  }

  Future<void> _connectToBtDevice(BluetoothDevice device) async {
    debugPrint("Connecting to device: ${device.advName}, ${device.remoteId}");
    btDevice = device;

    // Listen to device connection state
    deviceStateSubscription = btDevice.connectionState.listen((BluetoothConnectionState state) async {
      debugPrint("Device connection state changed: ${state.name}");
      if (state == BluetoothConnectionState.disconnected) {
        // 1. typically, start a periodic timer that tries to
        //    reconnect, or just call connect() again right now
        // 2. you must always re-discover services after disconnection!
        debugPrint("Device disconnected: ${btDevice.disconnectReason?.code} ${btDevice.disconnectReason?.description} finished connection? ${_btConnected}");
        if (_btConnected) {
          _webview.runJavaScript('window.FlutterMessages.onBtDisconnected()');
        }
        _btConnected = false;
      }
    });

    // cleanup: cancel subscription when disconnected
    //   - [delayed] This option is only meant for `connectionState` subscriptions.
    //     When `true`, we cancel after a small delay. This ensures the `connectionState`
    //     listener receives the `disconnected` event.
    //   - [next] if true, the the stream will be canceled only on the *next* disconnection,
    //     not the current disconnection. This is useful if you setup your subscriptions
    //     before you connect.
    btDevice.cancelWhenDisconnected(deviceStateSubscription, delayed:true, next:true);

    // Connect to the device
    await btDevice.connect();

    // Find service
    List<BluetoothService> services = await device.discoverServices();
    final service = services
        .singleWhere((service) => service.uuid == Guid(WALL_SERVICE_ID));

    // Find characteristic
    btCharacteristic = service.characteristics
        .singleWhere((characteristic) => characteristic.uuid == Guid(WALL_CHARACTERISTIC_ID));
    final subscription = btCharacteristic.onValueReceived.listen((value) {
      String message = String.fromCharCodes(value);
      if (value == lastBtMessage) {
        // TODO: Not good enough, we need to filter by "command" field, only commands from wall
        return;
      }
      debugPrint("Got BT message from wall! $message");

      _webview.runJavaScript("window.FlutterMessages.onBtMessage(${jsonEncode(message)})");
    });
    device.cancelWhenDisconnected(subscription);
    await btCharacteristic.setNotifyValue(true);
    _webview.runJavaScript('window.FlutterMessages.onBtConnectionResult("${device.advName}")');
    _btConnected = true;
  }


  // Future<void> _connectToBoardBluetoothOLDDD() async {
  //   dynamic connected = false;
  //   try {
  //     // Scan for devices
  //     dynamic scanDevicesStream;
  //     scanDevicesStream = _ble.scanForDevices(withServices: [WALL_SERVICE_ID], scanMode: ScanMode.lowLatency).listen((device) async {
  //       debugPrint('Found device: ${device.name}, id: ${device.id}');
  //       debugPrint("ble stream ? ${_ble.connectedDeviceStream}");
  //       if (connected) {
  //         return;
  //       }
  //       if (device.serviceUuids.contains(WALL_SERVICE_ID)) {
  //         debugPrint('Connecting to ${device.name} (${device.id})...');
  //
  //         // Connect to the device
  //         final connection = _ble.connectToAdvertisingDevice(
  //           id: device.id,
  //           withServices: [WALL_SERVICE_ID],
  //           servicesWithCharacteristicsToDiscover: {
  //             WALL_SERVICE_ID: [WALL_CHARACTERISTIC_ID]
  //           },
  //           prescanDuration: const Duration(seconds: 5),
  //           // servicesWithCharacteristicsToDiscover: {serviceId: [char1, char2]},
  //           connectionTimeout: const Duration(seconds:  2),
  //         );
  //
  //         connected = true;
  //         scanDevicesStream.cancel();
  //
  //         // Listen to changes on connection state
  //         _btConnectionStream = connection.listen((connectionState) {
  //           // if (connectionState.connectionState == DeviceConnectionState.connected) {
  //             debugPrint('Connected to ${device.name}');
  //
  //             // Subscribe to characteristic
  //             characteristic = QualifiedCharacteristic(
  //                 serviceId: WALL_SERVICE_ID, characteristicId: WALL_CHARACTERISTIC_ID, deviceId: device.id);
  //             _ble.subscribeToCharacteristic(characteristic).listen((data) {
  //               debugPrint("GOT DATA! $data");
  //               final message = utf8.decode(data);
  //               debugPrint("Message string: $message");
  //               _webview.runJavaScript('window.FlutterMessages.onBtMessage("$message")');
  //             }, onError: (dynamic e) {
  //               debugPrint('BT subscription to characteristic error: $e');
  //             });
  //           // }
  //         }, onError: (dynamic e) {
  //           debugPrint('BT Connection error: $e');
  //           _webview.runJavaScript('window.FlutterMessages.onBtDisconnected()');
  //         });
  //
  //         // Finished
  //         _webview.runJavaScript('window.FlutterMessages.onBtConnected("${device.name}")');
  //       }
  //     });
  //   } catch (e) {
  //     debugPrint('Error connecting to BLE service: $e');
  //   }
  // }

  Future<void> _disconnectFromBoardBluetooth() async {
    if (_btConnected) {
      // Disconnect from device
      await btDevice.disconnect();

      // Cancel device state subscription to prevent duplicate listeners
      deviceStateSubscription.cancel();
    }
  }

  // Future<void> _disconnectFromBoardBluetoothOLD() async {
  //   // Strange functionality and no docu, but this answer explains this method of closing the stream:
  //   // https://github.com/PhilipsHue/flutter_reactive_ble/issues/27#issuecomment-590783845
  //   _btConnectionStream.cancel();
  // }

  void _sendMessageToBoardBluetooth(message) async {
    try {
      lastBtMessage = message;
      await btCharacteristic.write(message.codeUnits); // or utf8.encode(message)??
    } catch (e) {
      debugPrint("Error sending with bluetooth: $e");
    }
  }

  // void _sendMessageToBoardBluetoothOLD(message) async {
  //   try {
  //     await _ble.writeCharacteristicWithResponse(
  //         characteristic,
  //         value: utf8.encode(message)
  //     );
  //   } catch (e) {
  //     debugPrint("Error sending with bluetooth: $e");
  //   }
  // }
}


// import 'package:flutter/material.dart';
// import 'package:webview_flutter/webview_flutter.dart';
// import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
// import 'dart:convert'; // For encoding/decoding JSON messages
//
// void main() {
//   runApp(const MyApp());
// }
//
// class MyApp extends StatelessWidget {
//   const MyApp({super.key});
//
//   // This widget is the root of your application.
//   @override
//   Widget build(BuildContext context) {
//     return MaterialApp(
//       home: WebViewBLEPage(),
//     );
//   }
// }
//
// class WebViewBLEPage extends StatefulWidget {
//   const WebViewBLEPage({super.key});
//
//   @override
//   WebViewBLEPageState createState() => WebViewBLEPageState();
// }
//
// class WebViewBLEPageState extends State<WebViewBLEPage> {
//   late final WebViewController _webview;
//   final FlutterReactiveBle _ble = FlutterReactiveBle();
//
//   @override
//   void initState() {
//     super.initState();
//     _webview = WebViewController()
//       ..setJavaScriptMode(JavaScriptMode.unrestricted)
//       ..setBackgroundColor(Colors.transparent)
//       ..setNavigationDelegate(
//         NavigationDelegate(
//           onPageStarted: (String url) {
//             print("Page started loading: $url");
//           },
//           onPageFinished: (String url) {
//             print("Page finished loading: $url");
//           },
//         ),
//       )
//       ..addJavaScriptChannel(
//         'BLEChannel',
//         onMessageReceived: (message) async {
//           final data = jsonDecode(message.message);
//           if (data['action'] == 'scan') {
//             _scanDevices();
//           } else if (data['action'] == 'connect') {
//             await _connectToDevice(data['deviceId']);
//           }
//         },
//       )
//       ..loadRequest(Uri.parse('https://whol.onrender.com'));
//   }
//
//   @override
//   Widget build(BuildContext context) {
//     return Scaffold(
//       appBar: AppBar(title: Text("WebView with BLE")),
//       body: WebViewWidget(controller: _webview),
//     );
//   }
//
//   void _scanDevices() {
//     _ble.scanForDevices(withServices: []).listen((device) {
//       final deviceInfo = jsonEncode({'id': device.id, 'name': device.name});
//       _webview.runJavaScript('onBLEDeviceDiscovered($deviceInfo)');
//     });
//   }
//
//   Future<void> _connectToDevice(String deviceId) async {
//     final connection = _ble.connectToDevice(id: deviceId);
//     connection.listen((state) {
//       if (state.connectionState == DeviceConnectionState.connected) {
//         _webview.runJavaScript('onBLEDeviceConnected("$deviceId")');
//       }
//     });
//   }
// }
