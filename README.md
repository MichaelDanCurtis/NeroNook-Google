# Google Workspace for NeroNook

Independent native Google module with Calendar, Inbox, Tasks and Files panels. Owns its Google OAuth flow, service selection, credentials, network requests and views. NeroNook only renders the shared SDK snapshots and optional agenda-v1 entries. The plugin builds from its vendored SDK without host source and opens a standalone 16:9 workspace.

Import previous Nook setup in Settings → Developer setup copies only Desktop client configuration and selected services. Sign in again in this plugin. Previous host configuration and tokens remain untouched. Credentials use this plugin's separate Keychain namespace; no token transplant or new cloud project is involved.

Build/test with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Package using `python3 Tools/nook.py pack . --identity <identity>`. Check the packaged runtime with `python3 scripts/check-process.py /absolute/path/to/app`. That check explicitly skips loading the account and performs no network requests. The generic creator's demo replay is not this integration's acceptance test.

The inherited Google implementation and tests were extracted from NeroNook 0.15.0. Calendar entries have a maximum ten-minute source-data lifetime and are removed from the host on disconnect/disable or expiry. Agenda includes the selected calendar day and today. Inbox and files are metadata only; Open hands off to the corresponding Google page. No mail sending, task editing or event mutations are implemented.

Live sign-in and data sync, independent packaging, host rendering and automated tests are separate acceptance gates. Public OAuth verification, distribution licensing/signing and notarization remain release work.

September 23 live check: the module signed in with its own account and displayed four calendars with a recent successful Calendar sync. Gmail, Tasks and Drive each reported denied access. The selected day was empty; populated host-agenda acceptance remains open. No denied service is counted as synced.
