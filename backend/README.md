# Easea cut planner (Claude)

A small Cloudflare Worker that the app calls to decide what to cut. The phone transcribes
the video on-device and sends only the word-timed transcript. This service asks Claude which
words to remove and returns a cut plan. The Anthropic API key never ships in the app.

## Deploy

```sh
cd backend
npm install
npx wrangler login
npx wrangler secret put ANTHROPIC_API_KEY     # from console.anthropic.com
npx wrangler secret put EASEA_APP_TOKEN       # any long random string; the app sends it
npm run deploy                                 # prints https://easea-cut-planner.<you>.workers.dev
```

Then point the app at it, either in **You → AI editor** (server address and app token) or by
setting `AppConfig.defaultPlannerURL` / `defaultAppToken` in `apple/Easea/Services/ClaudeEditor.swift`.

Local development: put `ANTHROPIC_API_KEY=...` in `backend/.dev.vars` (gitignored), run
`npm run dev`, and use `http://localhost:8787` as the server address in a simulator build.

## API

`POST /v1/cut-plan` with header `X-Easea-Token: <EASEA_APP_TOKEN>`:

```json
{
  "sources": [{ "duration": 12.4, "words": [{ "t": "hey", "s": 0.12, "e": 0.41 }] }],
  "pace": "natural",
  "removeFillers": true,
  "removeRetakes": true
}
```

The response says which word ranges to drop (inclusive indices into each source's `words`) and why:

```json
{
  "cuts": [{ "source": 0, "first_word": 0, "last_word": 3, "reason": "retake" }],
  "corrections": [{ "source": 0, "word": 9, "text": "BrainTree" }],
  "title": "Focus + hydration in one drink",
  "summary": "Kept the second take of the intro and removed two filler words."
}
```

`reason` is one of `retake`, `false_start`, `filler`, `stumble`, `rambling` or `off_script`.
Errors come back as `{ "error": "..." }`. If any request fails, the app falls back to its
on-device editor.

## How it uses Claude

- Model `claude-opus-5-5` with `effort: "medium"` and adaptive thinking. The editing rules are
  in `SYSTEM_PROMPT` in `src/planner.ts`.
- **Structured outputs** (`output_config.format` with a JSON schema): the reply always matches
  the plan shape. The server still checks every range against the real word counts.
- The system prompt is marked for **prompt caching**, so repeated requests reuse it.
- **Server-side fallback** (`fallbacks: "default"`): if the model declines, the request is
  retried on Anthropic's recommended fallback model. A refusal that still gets through returns
  HTTP 422.
- Responses are **streamed** (`finalMessage()`), so long transcripts don't hit HTTP timeouts.

The transcript is numbered word by word and split into lines at pauses, with the pause lengths
shown. That makes repeated takes easy to spot. See `renderTranscript`.

## Tests

```sh
npm test          # transcript rendering, plan checks, the HTTP handler (Claude is mocked)
npm run typecheck
```

## Before launch

The shared app token only keeps casual callers out. Before a public release, add per-user
authentication (for example Sign in with Apple plus App Attest) and per-user rate limits,
for example with Cloudflare rate limiting.
