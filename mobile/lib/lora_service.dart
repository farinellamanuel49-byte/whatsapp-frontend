import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Lora — sincronizzazione con Apple Music senza Apple Developer account.
///
/// Usa la sessione web di music.apple.com (login Apple ID normale) e
/// chiama l'API privata del web player (amp-api.music.apple.com) da
/// dentro la WebView, così i cookie di sessione vanno automaticamente.
///
/// Fase 1: login + scoperta token (media-user-token e developer JWT
/// pubblico del web player) + test di lettura.
/// Fase 2: ricerca catalogo e aggiunta brani in libreria.
class LoraService extends ChangeNotifier {
  LoraService();

  static const _home = 'https://music.apple.com';

  WebViewController? _controller;
  bool _probeRunning = false;

  /// Token per utente catturato dalla sessione web.
  String? mediaUserToken;

  /// Developer JWT pubblico del web player (ruota ogni ~2 mesi,
  /// lo rileviamo dalla pagina ad ogni probe).
  String? developerToken;

  String status = 'non configurato';
  final List<String> log = [];

  bool get connected => mediaUserToken != null && developerToken != null;

  void _log(String msg) {
    log.add('${DateTime.now().toString().substring(11, 19)} $msg');
    if (log.length > 200) log.removeRange(0, log.length - 200);
    notifyListeners();
  }

  /// Crea (una volta) la WebView e carica music.apple.com.
  WebViewController ensureController() {
    final c = _controller;
    if (c != null) return c;
    final ctl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => probe(),
      ))
      ..loadRequest(Uri.parse(_home));
    _controller = ctl;
    return ctl;
  }

  /// Ritorna true se l'utente ha già una sessione Apple nel webview
  /// (cookie persistiti da login precedente).
  Future<bool> hasSession() async {
    try {
      // music.apple.com risponde con la pagina home sia loggati sia
      // anonimi: il probe è l'unico modo affidabile per saperlo.
      return await probe();
    } catch (_) {
      return false;
    }
  }

  /// Esegue lo script di scoperta nella pagina e estrae i token.
  /// Ritorna true se entrambi i token sono stati trovati.
  Future<bool> probe() async {
    if (_probeRunning) return connected;
    _probeRunning = true;
    status = 'analisi sessione…';
    notifyListeners();
    try {
      final raw = await ensureController().runJavaScriptReturningResult(_probeJs);
      final json = _unwrapJs(raw);
      final data = jsonDecode(json) as Map<String, dynamic>;

      final jwt = data['jwt'] as String?;
      final mut = data['mut'] as String?;
      if (jwt != null && jwt.isNotEmpty) developerToken = jwt;
      if (mut != null && mut.isNotEmpty) mediaUserToken = mut;

      _log('url: ${data['url']}');
      _log('jwt: ${jwt == null ? 'NON trovato' : 'trovato (${jwt.length} char)'}');
      _log('mut: ${mut == null ? 'NON trovato' : 'trovato (${mut.length} char)'}');
      final lsKeys = (data['lsKeys'] as List?)?.join(', ') ?? '';
      if (lsKeys.isNotEmpty) _log('localStorage: $lsKeys');
      final err = data['error'] as String?;
      if (err != null) _log('errore JS: $err');

      // Test chiamata API se abbiamo almeno il jwt.
      if (developerToken != null) {
        await _testApi();
      }

      status = connected ? 'connesso' : 'login richiesto';
      notifyListeners();
      return connected;
    } catch (e) {
      status = 'errore probe: $e';
      _log('probe fallito: $e');
      notifyListeners();
      return false;
    } finally {
      _probeRunning = false;
    }
  }

  /// Test GET /v1/me/account su amp-api con i token trovati.
  Future<void> _testApi() async {
    final js = '''
(function(){
  var h={'authorization':'Bearer ${developerToken}'};
  ${mediaUserToken != null ? "h['media-user-token']='$mediaUserToken';" : ''}
  h['x-apple-client-version']='2646.4.0-external';
  h['Origin']='https://music.apple.com';
  return fetch('https://amp-api.music.apple.com/v1/me/account?l=en',{credentials:'include',headers:h})
    .then(function(r){return r.text().then(function(t){return JSON.stringify({status:r.status,body:t.slice(0,600)})})})
    .catch(function(e){return JSON.stringify({status:-1,body:String(e)})});
})()
''';
    try {
      // runJavaScriptReturningResult non aspetta le promise: usiamo
      // un trucco — la fetch è async, quindi memorizziamo in window
      // e poi leggiamo dopo un delay nel chiamante.
      await ensureController().runJavaScript('''
window.__loraApiResult=null;
$js.then(function(r){window.__loraApiResult=r});
''');
      await Future.delayed(const Duration(seconds: 4));
      final raw = await ensureController()
          .runJavaScriptReturningResult('window.__loraApiResult||"pending"');
      final s = _unwrapJs(raw);
      _log('API /me/account → $s');
    } catch (e) {
      _log('test API fallito: $e');
    }
  }

  /// Forza un nuovo probe (dopo login manuale nella webview).
  Future<void> refresh() => probe();

  /// Segna Lora come disconnesso (x sul login).
  void disconnect() {
    mediaUserToken = null;
    developerToken = null;
    status = 'disconnesso';
    notifyListeners();
  }

  /// JS che ispeziona la pagina music.apple.com e restituisce JSON con:
  /// - jwt: developer token pubblico (pattern JWT WebPlayKid)
  /// - mut: media-user-token (pattern numero + base64 lungo)
  /// - lsKeys: chiavi localStorage (per debug)
  /// - url/title: contesto
  static const _probeJs = r'''
(function(){
  try {
    var res={url:location.href,title:document.title,lsKeys:[],jwt:null,mut:null,error:null};
    var jwtRe=/eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6IldlYlBsYXlLaWQifQ\.[A-Za-z0-9_\-\.]{50,}/g;
    var mutRe=/\b\d{1,3}\.[A-Za-z0-9\/+_\-=]{60,}/g;
    function scanStore(store,prefix){
      try{
        for(var i=0;i<store.length;i++){
          var k=store.key(i); res.lsKeys.push(prefix+k);
          var v=''; try{v=store.getItem(k)||''}catch(e){}
          if(!res.jwt){var m=v.match(jwtRe); if(m)res.jwt=m[0];}
          if(!res.mut){var m2=v.match(mutRe); if(m2)res.mut=m2[0].slice(0,300);}
          if(v.length<4000){
            if(!res.jwt){var m3=v.match(jwtRe); if(m3)res.jwt=m3[0];}
          }
        }
      }catch(e){}
    }
    scanStore(localStorage,'ls:');
    scanStore(sessionStorage,'ss:');
    // cerca nei cookie (quelli non httpOnly)
    try{
      var ck=document.cookie||'';
      var m=ck.match(jwtRe); if(m&&!res.jwt)res.jwt=m[0];
      var m2=ck.match(mutRe); if(m2&&!res.mut)res.mut=m2[0].slice(0,300);
    }catch(e){}
    // cerca nel DOM inline (bootstrap state, config)
    try{
      var html=document.documentElement.innerHTML||'';
      if(!res.jwt){var m4=html.match(jwtRe); if(m4)res.jwt=m4[0];}
      if(!res.mut){var m5=html.match(mutRe); if(m5)res.mut=m5[0].slice(0,300);}
    }catch(e){}
    return JSON.stringify(res);
  }catch(e){return JSON.stringify({error:String(e&&e.stack||e)})}
})()
''';

  /// runJavaScriptReturningResult può restituire String o Map a
  /// seconda della piattaforma: normalizza a String JSON.
  String _unwrapJs(dynamic raw) {
    if (raw == null) return '{}';
    if (raw is String) {
      // iOS a volte wrappa in "'...'" o restituisce oggetto serializzato
      var s = raw.trim();
      if (s.startsWith("'") && s.endsWith("'")) {
        s = s.substring(1, s.length - 1);
      }
      return s;
    }
    return jsonEncode(raw);
  }
}
