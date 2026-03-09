## 0.3.0

- Harden SDK to never crash host app
- Remove throws from all public API methods — silently no-op if called before configure()
- Fix DateTime.parse crash on malformed server timestamps

## 0.2.1

- Fix kill switch response key (`sdk_enabled` → `sdkEnabled`)

## 0.2.0

- Use SDK key as sole credential — `configure(apiKey:)` replaces `configure(appId:)`
- Add Google Play Install Referrer for deterministic Android attribution
- Centralize version string via `appReferVersion` constant
- Remove backendUrl from public API

## 0.1.0

- Initial release
