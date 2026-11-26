import Anthropic from "@anthropic-ai/sdk";
import { PlanError, PlanRequestSchema, planCut } from "./planner";

export interface Env {
  ANTHROPIC_API_KEY: string;
  /** Shared secret the app sends in `X-Easea-Token`. Unset = open (local dev only). */
  EASEA_APP_TOKEN?: string;
}

const MAX_BODY_BYTES = 3_000_000;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/** Constant-time comparison so the token can't be guessed byte by byte. */
function tokensMatch(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const x = enc.encode(a);
  const y = enc.encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

export async function handle(request: Request, env: Env, client?: Anthropic): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/health") return json({ ok: true });
  if (url.pathname !== "/v1/cut-plan") return json({ error: "Not found" }, 404);
  if (request.method !== "POST") return json({ error: "Use POST" }, 405);

  if (
    env.EASEA_APP_TOKEN &&
    !tokensMatch(request.headers.get("x-easea-token") ?? "", env.EASEA_APP_TOKEN)
  ) {
    return json({ error: "Unauthorized" }, 401);
  }
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY_BYTES) {
    return json({ error: "Transcript too large" }, 413);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: "Body must be JSON" }, 400);
  }
  const parsed = PlanRequestSchema.safeParse(body);
  if (!parsed.success)
    return json({ error: "Invalid request", details: parsed.error.issues.slice(0, 5) }, 400);

  const anthropic = client ?? new Anthropic({ apiKey: env.ANTHROPIC_API_KEY });
  try {
    const plan = await planCut(anthropic, parsed.data);
    return json(plan);
  } catch (error) {
    if (error instanceof PlanError) return json({ error: error.message }, error.status);
    if (error instanceof Anthropic.RateLimitError)
      return json({ error: "Busy, try again shortly" }, 429);
    if (error instanceof Anthropic.AuthenticationError) {
      console.error("Anthropic authentication failed - check ANTHROPIC_API_KEY");
      return json({ error: "Editor unavailable" }, 503);
    }
    if (error instanceof Anthropic.APIError) {
      console.error(`Anthropic API error ${error.status}: ${error.message}`);
      return json({ error: "Editor unavailable" }, 502);
    }
    console.error(error);
    return json({ error: "Editor failed" }, 500);
  }
}

export default {
  fetch: (request, env) => handle(request, env),
} satisfies ExportedHandler<Env>;
