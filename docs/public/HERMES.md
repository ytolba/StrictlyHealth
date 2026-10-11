# Optional Hermes connection

Youra’s measurements, voice journal, patterns and morning brief work offline.
Hermes is an optional explanation layer on **your own server**. Nothing is
shared by default; the optional self-hosted iMessage bridge must be installed
separately by each user.

## Server checklist — before sharing any health text

1. Install and configure Hermes using its [official setup guide](https://hermes-agent.nousresearch.com/docs/getting-started/quickstart/).
2. Create a separate health-only profile or isolated instance using [profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles/). Do not copy personal workspaces, credentials, memories, skills, plugins, or messaging connections into it.
3. In that profile, run `hermes tools`, select the API-server platform, and disable **every tool**, including terminal, files, browser/web, code execution, delegation, cron, memory, session search, skills, images, and external/MCP integrations. Inspect the saved configuration. A preset named “safe” is not equivalent to no tools.
4. Use the documented `agent.disabled_toolsets` configuration as defense in depth. Disable external memory providers and remove integrations/plugins/MCP servers. Check available groups for your installed release; future tools need a fresh audit. See [configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration/) and [toolsets](https://hermes-agent.nousresearch.com/docs/reference/toolsets-reference).
5. Enable the API server and give the dedicated instance/profile a strong, unique `API_SERVER_KEY`. Bind the internal listener privately; expose it only through authenticated HTTPS with a trusted certificate, ideally over your private network/VPN. Do not open an unauthenticated public port.
6. Restart and inspect the API platform’s resolved `/v1/toolsets` response and server logs. No enabled executable tools should remain. Test using synthetic text first; confirm no tool execution, external delivery or memory recall. The app’s connection test only checks `/v1/models`, **not** these restrictions.

The [official API guide](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server/) documents enabling the listener and profile routes. Normal Hermes has broad tools; a client system prompt does **not** remove them. Youra cannot enforce restrictions or retention settings on a remote server. Do not send real data until you have verified your configuration.

## In Youra

Open **Settings → AI & Messages**. Enter your HTTPS API base URL, model
(normally `youra` for the dedicated Youra API profile), and bearer token. Save the token securely, then test.
Use a URL such as `https://your-private-host.example/v1`, or the full named-profile
base `https://your-private-host.example/p/youra/v1` with that profile’s own token.
These are placeholders, not provided servers. iPhone localhost refers to the
iPhone, not your Mac. No insecure-HTTP or invalid-certificate exceptions exist.

Open **Today → Talk to Youra → Hermes**. Record locally or type, select whether
to include the latest valid night and a confirmed check-in for the chosen date,
then **Review message & context → Send**. Follow-up turns can optionally include
the previous reply, also visible in the preview. Replies can be read aloud or muted.
Conversations are short explicit turns, not an always-listening live stream.
AI text never changes metrics or saves habits. The journal-draft action parses
your own message, not the agent reply, and still requires Save confirmation.

## Optional daily Oura iMessage

On macOS, the self-hosted bridge in `tools/morning-brief/` accepts one compact,
validated direct-Bluetooth Oura sleep summary from the iPhone, asks the dedicated
Youra API profile for a short message, then uses the already-configured Photon
home channel to send it. It never reads Apple Health, account exports, voice
journal entries, ring identifiers, or raw samples. If Oura data has not reached
the Mac by ten minutes after its recorded wake time, that night is skipped.

The bridge binds only to `127.0.0.1:8643`; it requires the same bearer key as the
Youra API profile. Its pending summary is stored with owner-only permissions in
`~/Library/Application Support/Youra/MorningBrief/` and removed after delivery.
The model call uses the Youra profile, which must keep every executable tool
disabled. The configured model/provider receives the sleep summary; a local
Ollama model keeps that inference on the Mac, while a cloud model may transmit or
retain it elsewhere. Photon then sends the generated text to its configured
iMessage destination.

To install the bridge from this repository on macOS:

1. Keep Hermes and Photon working, and verify `hermes send --list photon` shows
   the intended personal destination.
2. Run `python3 tools/morning-brief/install.py`. This installs a per-user
   LaunchAgent; it does not change the Hermes gateway or messaging configuration.
3. Add the private HTTPS route to the existing tailnet Serve setup:
   `tailscale serve --bg --https=443 --set-path=/youra-morning-brief http://127.0.0.1:8643`.
   Confirm `tailscale serve status --json` still lists the Hermes `/` route and
   the new `/youra-morning-brief` route. Do not enable Funnel or expose this
   health endpoint publicly.
4. In Youra, open **Settings → AI & Messages**, enter the Youra HTTPS API URL and
   API key, test the connection, then enable **Send my sleep brief**. The phone
   must be on the tailnet and finish an Oura Bluetooth sync before the scheduled
   delivery time. The app skips Apple Health, incomplete nights, late syncs, and
   duplicate deliveries.

`python3 tools/morning-brief/install.py --uninstall` removes only this bridge
LaunchAgent. It does not delete the Hermes gateway, Photon setup, or app data.

## Data flow and retention

- Microphone → on-device English recognition → editable transcript in memory. No audio files or network speech fallback.
- Confirmed structured habits → separate protected local journal file; existing SwiftData cache and pairing identifiers are unchanged. Backups may include journal/health files.
- Manual AI chat: Review → explicit Send → HTTPS Chat Completions request containing displayed text and fixed assistant instructions. The optional daily iMessage uses only the separate direct-Oura summary above; enabling it is an explicit opt-in.
- Manual chats include only selected formatted facts, confirmed entries and optionally the previous reply. The daily brief includes only the direct Oura sleep fields named above. No raw samples, serials, pairing keys, full database, or other journal dates are sent. Anything sensitive you type yourself is still part of your approved manual message.
- Token → separate device-only Keychain account, never the ring-key account. Session uses no disk cache/cookies and refuses redirects.
- Server/provider → may log, retain or bill for submitted text. Stateless client requests do not guarantee server-side deletion. Cancellation cannot recall a request already delivered.

Before enabling this integration, verify your own Hermes profile with synthetic
text and confirm that its resolved API toolsets contain no executable tools.
Repository tests cover authentication, malformed replies, offline failures,
cancellation, schedule validation and no-send behavior. Repeat the server-side
restriction audit whenever Hermes or its plugins are upgraded.
