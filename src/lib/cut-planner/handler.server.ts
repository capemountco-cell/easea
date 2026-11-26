import Anthropic from "@anthropic-ai/sdk";
import { PlanError, PlanRequestSchema, planCut } from "./planner.server";

/** Server secrets, set in Lovable (Project settings → Secrets). */
export interface PlannerEnv {
  /** Anthropic API key. `CLAUDE_API_KEY` is accepted as an alternative name. */
  apiKey: string | undefined;
  /** Shared secret the iOS/macOS app sends in `X-Easea-Token`. Unset = open (development only). */
  appToken: string | undefined;
}

/** Reads secrets from the server environment (Lovable exposes them as environment variables). */
export function readPlannerEnv(): PlannerEnv {
  const env =
    (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env ?? {};
  return {
    apiKey: env["ANTHROPIC_API_KEY"] ?? env["CLAUDE_API_KEY"],
    appToken: env["EASEA_APP_TOKEN"],
  };
}

const MAX_BODY_BYTES = 3_000_000;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
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

/** `POST /api/cut-plan`: transcript in, Claude's cut plan out. */
export async function handleCutPlan(
  request: Request,
  env: PlannerEnv,
  client?: Anthropic,
): Promise<Response> {
  if (env.appToken && !tokensMatch(request.headers.get("x-easea-token") ?? "", env.appToken)) {
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
  if (!parsed.success) {
    return json({ error: "Invalid request", details: parsed.error.issues.slice(0, 5) }, 400);
  }

  if (!client && !env.apiKey) {
    console.error("ANTHROPIC_API_KEY is not set in the project's secrets");
    return json({ error: "Editor unavailable" }, 503);
  }
  const anthropic = client ?? new Anthropic({ apiKey: env.apiKey });
  try {
    const plan = await planCut(anthropic, parsed.data);
    return json(plan);
  } catch (error) {
    if (error instanceof PlanError) return json({ error: error.message }, error.status);
    if (error instanceof Anthropic.RateLimitError) {
      return json({ error: "Busy, try again shortly" }, 429);
    }
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
