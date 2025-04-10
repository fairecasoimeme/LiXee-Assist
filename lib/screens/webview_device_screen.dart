import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebViewDeviceScreen extends StatefulWidget {
  final String deviceName;
  final String url; // 🔥 URL contenant l'IP résolue

  const WebViewDeviceScreen({required this.deviceName, required this.url});

  @override
  _WebViewDeviceScreenState createState() => _WebViewDeviceScreenState();
}

class _WebViewDeviceScreenState extends State<WebViewDeviceScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    print("🌍 Chargement WebView : ${widget.url}");

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() => _isLoading = true);
          },
          onPageFinished: (url) {
            setState(() => _isLoading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
        child:  Scaffold(
          appBar: AppBar(title: Text("🔗 ${widget.deviceName}")),
          body: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_isLoading)
                const Center(
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ),
    );
  }
}
