# Music Downloader (mobile)

App Flutter per Android e iOS che scarica audio/video tramite il proxy
`server.js` del progetto (API yt-dlp) e, su iOS, si collega ad Apple Music
per la riproduzione in streaming della libreria.

## Architettura

- L'app NON contiene la chiave API: parla solo con il proxy Node esistente
  (`/api/download/stream`, `/api/health`). Configura l'URL del server nelle
  Impostazioni (deve essere raggiungibile dal telefono, es. IP LAN).
- Download: `dio` → file in `Documents/downloads/` con progresso e coda
  persistente (`downloads.json`).
- Player locale: `just_audio` con coda dei brani scaricati.
- Apple Music (solo iOS): plugin `music_kit` per riproduzione in streaming +
  API REST `api.music.apple.com` per ricerca catalogo e libreria.

## Primo avvio

```bash
cd mobile
flutter create .          # genera android/ e ios/ (serve Flutter SDK)
flutter pub get
flutter run
```

Nelle **Impostazioni** dell'app inserisci l'URL del server, es.
`http://192.168.100.14:8080` (stesso IP delle `API_BASES` di server.js).

## Permessi e configurazione piattaforme

Dopo `flutter create .`:

### Android — `android/app/src/main/AndroidManifest.xml`

Aggiungi dentro `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
```

(I file sono salvati nella directory privata dell'app: nessun permesso di
storage necessario. Per vederli in un file manager esterno serve un export
successivo via MediaStore/SAF — non ancora implementato.)

### iOS — `ios/Runner/Info.plist`

Per rendere i download visibili in "File" (Su iPhone → Music Downloader):

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
<key>NSAppleMusicUsageDescription</key>
<string>Usato per riprodurre in streaming la tua libreria Apple Music.</string>
```

In Xcode: scheda *Signing & Capabilities* → aggiungi **MusicKit** e abilita
*In-App Purchase* non serve; serve il provisioning con l'App ID abilitato
per MusicKit.

## Apple Music: token necessari

La scheda Apple Music richiede due valori (Impostazioni → Apple Music):

1. **Developer token** — JWT firmato con la chiave MusicKit dell'Apple
   Developer account (Apple Developer → Certificates → MusicKit). In
   produzione va generato server-side (chiave privata mai nell'app).
   Per sviluppo puoi generarne uno temporaneo con tools come
   `jwt` + la chiave `.p8`.
2. **Music-User-Token** — opzionale ma necessario per la *libreria* e lo
   store privato: lo si ottiene dopo l'autorizzazione MusicKit
   (`musicKit.requestUserToken(developerToken)`).

`storefront` = codice paese a due lettere (default `it`).

## Sincronizzazione Apple Music (iOS)

La sincronizzazione è **automatica**: a fine download di ogni brano audio,
l'app cerca il brano nel catalogo Apple Music e lo aggiunge alla **tua
libreria** (`POST /v1/me/library`) — appare in "Aggiunti di recente" e si
sincronizza via iCloud su tutti i dispositivi Apple. Nella scheda Download
compare il contatore "N su Apple Music" e un pulsante per ri-sincronizzare
manualmente tutti i brani.

Requisiti: **Music-User-Token** configurato (obbligatorio per scrivere in
libreria) e abbonamento Apple Music attivo per la riproduzione.

I file audio scaricati restano comunque nell'app: Apple non consente di
copiare brani protetti DRM dentro l'app Music — la sincronizzazione copre
la *libreria* (metadati + streaming), non il file.
- L'app può essere rifiutata in App Store review se distribuita come
  downloader di contenuti protetti: valuta un modello con solo contenuti
  autorizzati o distribuzione fuori dallo store.
- I download yt-dlp richiedono ~8-10s di validazione lato server.
