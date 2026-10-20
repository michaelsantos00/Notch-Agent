# Private provider-only build

This branch hardens NotchAgent for private local use. Its app-managed provider requests go directly to exact approved provider origins. There is no upstream updater, automatic pricing service, or embedded browser login in this build.

## Network behavior

`Sources/Model/NetworkPolicy.swift` is the canonical allowlist. Each built-in provider uses its own scope. Remote requests require HTTPS and an approved exact origin; cookies, credentials, caches, and proxies are not inherited from shared URLSession storage. All HTTP redirects are rejected, including redirects on an injected session. LM Studio WebSocket requests also carry the policy delegate. Existing loopback-only local model and relay boundaries remain in place.

The remote origins currently approved are:

| Provider | Hosts |
| --- | --- |
| Amp | ampcode.com |
| Antigravity | cloudcode-pa.googleapis.com, daily-cloudcode-pa.googleapis.com |
| Apify | api.apify.com |
| Claude | api.anthropic.com |
| Codex | chatgpt.com |
| Cursor | cursor.com |
| Command Code | api.commandcode.ai |
| Devin | server.self-serve.windsurf.com |
| GLM | open.bigmodel.cn, api.z.ai |
| GitHub Copilot | api.github.com |
| Grok | cli-chat-proxy.grok.com, accounts.x.ai, auth.x.ai |
| Kilo | api.kilo.ai |
| Kimi | api.kimi.com |
| Kiro | codewhisperer.us-east-1.amazonaws.com, q.eu-central-1.amazonaws.com |
| MiniMax | api.minimax.io, api.minimaxi.com, www.minimax.io, www.minimaxi.com |
| OpenCode | opencode.ai |
| Ollama cloud | ollama.com |

Providers that are disconnected are excluded from usage polling. Plan detection also requires that account to be explicitly authorized for history. Custom providers are an explicit extension of this list: saving or testing a custom endpoint authorizes its visible origin. A custom usage URL must share that origin. Remote HTTP, embedded URL credentials, and automatic probing with draft API keys are refused. Local custom endpoints may use HTTP on loopback. The self-signed TLS exception is confined to Antigravity's loopback bridge.

Sparkle and its feed/signing configuration are removed. Prices and plans use bundled or local files; currency conversion is entered manually. No OpenRouter pricing refresh, exchange-rate fetch, or remote plans URL runs automatically. An explicitly configured OpenRouter provider can still call OpenRouter.

Automatic Claude usage CLI calls, Claude token-renewal CLI calls, Kiro CLI calls, `gh auth token`, and login-shell executable discovery are disabled. Claude OAuth refresh still uses its direct provider API. DeepSeek/Qianwen embedded website sessions and MiniMax embedded sign-in are unavailable; direct API providers remain available. This avoids loading third-party website resources into the app. Phone Link remains unavailable in this macOS build.

Ollama is the one provider that can read a browser's sign-in, and only when the user switches its source from API key to Browser sign-in in Settings. Ollama's API reports request counts only; the session and weekly percentages appear solely on ollama.com/settings. In that mode NotchAgent reads the single `__Secure-session` cookie for exactly `ollama.com` (never a lookalike host) from the chosen browser profile (Safari, Chromium-family, or Firefox-family), holds it in memory, and sends it only to `https://ollama.com/settings` under the same Ollama scope and redirect rejection as the API. Cookie databases are read from a temporary copy and never written. Listing the signed-in browsers reads only cookie metadata; a Chromium browser's "Safe Storage" keychain key is requested only for the browser actually in use, and a declined request is not repeated until the user chooses Allow access. Safari's cookies require Full Disk Access, which NotchAgent does not request on its own.

Manual links and sign-in commands can open a browser, Terminal, or provider app at the user's request. Those separate applications have their own networking behavior. Running `agy` to develop the project uses Google's agent service; that tool is not bundled with NotchAgent.

## Local data

Transcript history indexing defaults to off and requires explicit account selection. Turning off history, deselecting an account, or disconnecting it stops its watcher and writers. Prompt and response fields are not persisted or transmitted; the indexer reads transcript files to extract timestamps, paths, session identifiers, model names, and token counts. These metadata can still be sensitive.

With indexing enabled, retention defaults to 30 days; zero means keep indefinitely. Pruning runs when history models open, when the retention preference changes, and hourly while history is enabled. Existing disabled-account databases are included. Cutoffs prevent reimporting old events and stale paths. Turning off indexing preserves existing history; use Clear Local History or Erase All Data to remove it.

App-owned cost directories and files use 0700/0600 permissions, including SQLite and its companion files. New JSON files are created privately and replaced atomically. This protects against other local user accounts, but is not encryption and does not isolate apps running as the same macOS user. Provider credentials remain in their existing provider storage; app-owned API keys use Keychain. Usage readings are cached in app preferences until sign-out or erasure.

Clear Local History stops writers and clears all regular app-owned history databases, including disabled and orphaned accounts. Configuration JSON files and API keys are preserved. Erase All Data coordinates application shutdown, blocks late archive writes and new provider requests, removes app preferences, Application Support, caches, WebKit/HTTPStorage data, saved state, and app-owned Keychain items, then quits. Borrowed provider credentials and original transcripts are preserved. A shutdown failure aborts deletion. A partial deletion failure is reported and background work stays paused until restart. Neither control was invoked on personal data during development.

## Scope of assurance

The policy is enforced in application code, with regression tests and local HTTP fixtures. It is not an operating-system firewall, an independent packet-capture certification, or a sandbox against malicious replacement code. Provider servers still receive the authentication and usage requests needed for their integration. macOS system services, DNS, manually opened external apps, and any upstream provider app are outside this policy.

This app remains unsandboxed because it reads existing provider credentials and files. Dependencies remain pinned in Package.resolved. Builds download development dependencies separately from application runtime. Upstream provider APIs can change; an unapproved new origin is blocked until reviewed and added.

## Build

```sh
make build DEV_SIGN='CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic'
make test DEV_SIGN='CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic'
```

The local build uses ad-hoc signing. No keychain ACL broadening script is required or was run. No global firewall, provider preference, shell initialization, or macOS security setting was changed.
