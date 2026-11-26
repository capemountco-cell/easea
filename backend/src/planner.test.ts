import { describe, expect, it } from "vitest";
import type Anthropic from "@anthropic-ai/sdk";
import { buildUserPrompt, renderTranscript, sanitizePlan, type PlanRequest } from "./planner";
import { handle } from "./index";

function words(script: string, t0 = 0): PlanRequest["sources"][number]["words"] {
  let t = t0;
  return script.split(" ").flatMap((token) => {
    if (token === "|") {
      t += 1.5;
      return [];
    }
    const w = { t: token, s: t, e: t + 0.3 };
    t += 0.4;
    return [w];
  });
}

const request: PlanRequest = {
  sources: [
    { duration: 8, words: words("hey guys today I | hey guys today I want to show you this") },
  ],
  pace: "natural",
  removeFillers: true,
  removeRetakes: true,
};

describe("renderTranscript", () => {
  it("numbers words and marks pauses", () => {
    const text = renderTranscript(request);
    expect(text).toContain("=== Clip 0 (8.0s) ===");
    expect(text).toContain("[0.0s] 0:hey 1:guys 2:today 3:I");
    expect(text).toMatch(/\[3\.\ds \+1\.\ds pause\] 4:hey 5:guys/);
  });

  it("reflects preferences in the prompt", () => {
    const prompt = buildUserPrompt({ ...request, removeFillers: false, pace: "tight" });
    expect(prompt).toContain("Pace: tight");
    expect(prompt).toContain("Keep filler words");
  });
});

describe("sanitizePlan", () => {
  it("clamps, merges and drops bad ranges", () => {
    const plan = sanitizePlan(
      {
        cuts: [
          { source: 0, first_word: 2, last_word: 3, reason: "retake" },
          { source: 0, first_word: 0, last_word: 1, reason: "retake" },
          { source: 0, first_word: 50, last_word: 60, reason: "filler" },
          { source: 3, first_word: 0, last_word: 1, reason: "filler" },
        ],
        corrections: [
          { source: 0, word: 4, text: "Hey" },
          { source: 0, word: 99, text: "nope" },
        ],
        title: "Showing you this",
        summary: "Removed the first take.",
      },
      request,
    );
    // Adjacent retake ranges merge; ranges past the last word or in a missing clip are dropped.
    expect(plan.cuts).toEqual([{ source: 0, first_word: 0, last_word: 3, reason: "retake" }]);
    expect(plan.corrections).toEqual([{ source: 0, word: 4, text: "Hey" }]);
  });

  it("rejects a plan that removes everything", () => {
    expect(() =>
      sanitizePlan(
        {
          cuts: [{ source: 0, first_word: 0, last_word: 12, reason: "rambling" }],
          corrections: [],
          title: "",
          summary: "",
        },
        request,
      ),
    ).toThrow(/everything/);
  });
});

describe("handle", () => {
  const fakeClient = (reply: object, stop_reason = "end_turn") =>
    ({
      beta: {
        messages: {
          stream: () => ({
            finalMessage: async () => ({
              stop_reason,
              content: [{ type: "text", text: JSON.stringify(reply) }],
            }),
          }),
        },
      },
    }) as unknown as Anthropic;

  const post = (body: unknown, token?: string) =>
    new Request("https://x/v1/cut-plan", {
      method: "POST",
      headers: { "content-type": "application/json", ...(token ? { "x-easea-token": token } : {}) },
      body: JSON.stringify(body),
    });

  it("requires the app token when configured", async () => {
    const res = await handle(
      post(request),
      { ANTHROPIC_API_KEY: "k", EASEA_APP_TOKEN: "secret" },
      fakeClient({}),
    );
    expect(res.status).toBe(401);
  });

  it("returns the sanitized plan", async () => {
    const reply = {
      cuts: [{ source: 0, first_word: 0, last_word: 3, reason: "retake" }],
      corrections: [],
      title: "Show you this",
      summary: "Kept the second take.",
    };
    const res = await handle(
      post(request, "secret"),
      { ANTHROPIC_API_KEY: "k", EASEA_APP_TOKEN: "secret" },
      fakeClient(reply),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual(reply);
  });

  it("maps a refusal to 422", async () => {
    const res = await handle(post(request), { ANTHROPIC_API_KEY: "k" }, fakeClient({}, "refusal"));
    expect(res.status).toBe(422);
  });

  it("rejects malformed requests", async () => {
    const res = await handle(post({ sources: [] }), { ANTHROPIC_API_KEY: "k" });
    expect(res.status).toBe(400);
  });
});
