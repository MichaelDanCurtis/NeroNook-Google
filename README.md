**October 23 · installed live reply path verified:** the owner-requested old
startup cancellation is reconciled with locked Dispatch non-admission proof.
One actual Gmail → Ember → local reply workflow completes. The edited draft
saves and reopens exactly after a managed Google restart; no reply email is sent.
App binaries remain unchanged. [Evidence and limits](../NeroNook/reports/nero-flow-recovery-2026-10-23/README.md).

**October 18 · local 0.1.5 installed:** shared glass, paired Light/Dark, independent bundled presence/particle artwork and component motion. Saved connection/settings remain scoped to this plugin. The package reuses its original stable signing identity; saved account restored after owner Keychain approval and one ordinary restart. Fresh Calendar and Gmail unread metadata are observed; no mail/file mutation occurred. [Rollout evidence and limits](../NeroNook/reports/redesign-ember-2026-10-18/README.md). No public release.

**October 13 · 0.1.4:** registers the optional generic read-only calendar SDK
adapter for explicit meeting links. It lists selected calendars and resolves
exact calendar/event/original occurrence IDs without changing the displayed
agenda day or requesting new scopes. Timed recurrence uses originalStartTime;
all-day recurrence keeps its original date across time-zone changes.
[Shared contract](../NeroNook/SDK/CALENDAR.md).

Saved account restoration runs off the main actor and initially disallows
Keychain UI so a locked/keychain prompt cannot stall plugin heartbeat. **Use
saved sign-in** allows a deliberate foreground unlock; Sign in / Reconnect
remain the normal owned OAuth flow. No credential transplant or weakened
Keychain control is introduced. Version 0.1.3's native heartbeat failure is
retained as a negative receipt; 0.1.4 is installed and Running. The existing
account reconnected normally and all four selected services report recent sync;
both Google SDK and native selected-day agenda were empty on October 13.
Fifteen tests and legacy / collections / calendar-action signed accountless
process checks pass. Populated personal-event linkage remains unverified.

# Google for NeroNook

Independent native Google module with Calendar, Inbox, Tasks and Files panels. Owns its Google OAuth flow, service selection, credentials, network requests and views. NeroNook only renders the shared SDK snapshots and optional agenda-v1 entries. The plugin builds from its vendored SDK without host source and opens a standalone 16:9 workspace.

Import previous Nook setup in Settings → Developer setup copies only Desktop client configuration and selected services. Sign in again in this plugin. Previous host configuration and tokens remain untouched. Credentials use this plugin's separate Keychain namespace; no token transplant or new cloud project is involved.

Build/test with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. Package using `python3 Tools/nook.py pack . --identity <identity>`. Check the packaged runtime with `python3 scripts/check-process.py /absolute/path/to/app`. That check explicitly skips loading the account and performs no network requests. The generic creator's demo replay is not this integration's acceptance test.

The inherited Google implementation and tests were extracted from NeroNook 0.15.0. Calendar entries have a maximum ten-minute source-data lifetime and are removed from the host on disconnect/disable or expiry. Agenda includes the selected calendar day and today. Inbox and files are metadata only; Open hands off to the corresponding Google page. No mail sending, task editing or event mutations are implemented.

Live sign-in and data sync, independent packaging, host rendering and automated tests are separate acceptance gates. Public OAuth verification, distribution licensing/signing and notarization remain release work.

September 23 live check: the module signed in with its own account and displayed four calendars with a recent successful Calendar sync. Gmail, Tasks and Drive each reported denied access. The selected day was empty; populated host-agenda acceptance remains open. No denied service is counted as synced.

September 23 update, 0.1.1: personal Gmail is supported explicitly. HTTP errors distinguish disabled APIs, missing scopes, organization policy, quota/rate limits and service outages, with service-specific recovery in Settings. Arbitrary response bodies are not shown. Invalid-access failures clear that service's stale data and sync time. Empty remote titles become valid display cards, and a rejected display snapshot yields an error view rather than stopping heartbeat updates.

Live acceptance: the existing personal Gmail login loaded 20 inbox headers, 3 tasks and 25 Drive files after project API enablement. Calendar remains connected with four calendars; the selected day has no events. No OAuth scope expansion or token transplant. Eleven tests and the signed accountless four-panel/agenda process check pass. A separate 25-second signed production-process read verified real populated snapshots without printing message subjects, file names or credentials. Error classification follows Google's documented structured reasons: https://developers.google.com/workspace/gmail/api/guides/handle-errors.

September 23 follow-up, 0.1.2: Calendar now uses a navigable month grid and day agenda; Inbox uses sender/subject/date rows, unread filtering and a selected-message summary; Tasks uses due-date rows and filters; Files uses list/grid layouts, file types, modified dates, search and name/recent sorting. These are provided through the independently vendored collections-v1 SDK, including the same renderer in the standalone window. Earlier hosts retain the card fallback. Calendar selection fetches the chosen day; unloaded days have no invented event counts. All existing scopes remain read-only. Task editing, message bodies and file content still open in Google.

Validation: thirteen tests pass, including daylight-saving/month-boundary grids and production empty-presentation validation. `scripts/check-collections.py` verifies negotiated layouts and calendar selection in the signed process without loading the account; the original process check verifies the legacy fallback. Native installed acceptance inspected all four layouts, next-month/Today navigation, 20 inbox messages / 19 unread, three task rows and 25 files with list/grid switching. The selected calendar day was empty; populated-event live rendering remains unverified. The previous 0.1.1 package remains available through the host's recovery UI.

Final signed package: `cafe.nero.plugin.google-0.1.2-95fd4bd21eef.app`. Installed and Running. The standalone 720×405 calendar and populated inbox were also visually checked. Inbox search returned no matches for an unmatched query, clearing it restored all 20 messages, and selection exposed a header summary plus Open in Gmail without opening external mail. The final Nook is left on Calendar.

## October 23 · selected reply items (0.1.7, installed locally)

Google now offers an explicit selection of up to five recent emails, plus optional
SDK `list_reply_selection` and `read_reply_item` actions. Metadata listing does
not fetch bodies. Item references pin account/selection and expire after one
hour; changing selection or restarting clears them. Legacy single-message and
local-draft action definitions remain unchanged. No OAuth scope expansion,
Gmail draft write or sending was added.

Three authored self-emails completed sequentially through Nero Flow and the
unchanged Ember 0.5.13 provider into three independent local reply drafts. Each
native Unicode/multiline edit reopened exactly after a managed restart; mode
0600. 28 Swift tests (one opt-in fixture skip), legacy/modern handshakes and
Developer ID local packaging pass. These are local acceptance checks, not a
public release or broader reply-quality certification. Full receipts are in the
host's `reports/nero-flow-mapping-2026-10-23/README.md`.
