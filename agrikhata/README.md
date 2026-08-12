# AgriKhata

Flutter desktop app for agricultural shop ledger, sales, partners, and cloud backup.

## Getting Started

```bash
cd agrikhata
flutter pub get
flutter run -d windows
```

## Google Drive OAuth (desktop)

Drive backup and desktop Google sign-in use a Google Cloud **Desktop** OAuth client.
Secrets must **not** be committed to Git.

### Local setup

```bash
cd agrikhata
copy .env.example .env
# Edit .env with your Desktop OAuth Client ID / Secret
```

`.env` is gitignored and registered as a Flutter asset so Windows release builds
bundle it for out-of-the-box OAuth. Keep real credentials only in `.env`.

### Resolution order

1. Values saved in **Settings** (SharedPreferences) — optional override
2. Bundled `.env` via `flutter_dotenv` (`GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`)
3. Compile-time `--dart-define=GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`

If the Client ID is missing, the app logs a warning and keeps Google OAuth
disabled instead of crashing.

### Production `.msix` builds

Prefer a release-machine `.env` next to `pubspec.yaml` so credentials ship in
assets. Alternatively bake defines:

```bash
flutter pub run msix:create --dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>"
```

### Setup checklist

1. Google Cloud Console → enable **Google Drive API**
2. Credentials → OAuth client ID → **Desktop app**
3. Authorized redirect URI (if prompted): `http://localhost:8765/`
4. Copy `.env.example` → `.env` and fill credentials before `flutter build windows`

## Demo / release package

```bash
# Ensure agrikhata/.env exists with GOOGLE_CLIENT_ID before packaging
build_demo.bat
```
