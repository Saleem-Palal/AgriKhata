# AgriKhata

Flutter desktop app for agricultural shop ledger, sales, partners, and cloud backup.

## Getting Started

```bash
cd agrikhata
flutter pub get
flutter run -d windows
```

## Google Drive OAuth (desktop)

Drive backup uses a Google Cloud **Desktop** OAuth client. Secrets must **not** be committed to Git.

### Resolution order

1. Values saved in **Settings** (SharedPreferences on the device)
2. Compile-time defines: `GOOGLE_CLIENT_ID` and optional `GOOGLE_CLIENT_SECRET`

If `GOOGLE_CLIENT_ID` is empty during development, the app logs a warning and keeps Drive backup disabled instead of crashing. Enter credentials in Settings, or pass defines at build time.

### Production `.msix` builds

Bake the Client ID into the package (never hardcode it in source):

```bash
flutter pub run msix:create --dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>"
```

Optional secret (only if your OAuth client requires it):

```bash
flutter pub run msix:create ^
  --dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>" ^
  --dart-define=GOOGLE_CLIENT_SECRET="<CLIENT_SECRET>"
```

Or set an environment variable and use `build_demo.bat` (Windows), which forwards `GOOGLE_CLIENT_ID` when present.

### Setup checklist

1. Google Cloud Console → enable **Google Drive API**
2. Credentials → OAuth client ID → **Desktop app**
3. Authorized redirect URI (if prompted): `http://localhost:8765/`
4. Pass `GOOGLE_CLIENT_ID` via `--dart-define` for release builds, or enter it once in Settings for local testing

## Demo / release package

```bash
# Optional: set before running so MSIX embeds the Client ID
set GOOGLE_CLIENT_ID=your-id.apps.googleusercontent.com
build_demo.bat
```
