import { createFileRoute } from "@tanstack/react-router";
import { handleCutPlan, readPlannerEnv } from "@/lib/cut-planner/handler.server";

// Called by the Easea iOS/macOS app: on-device transcript in, Claude's cut plan out.
export const Route = createFileRoute("/api/cut-plan")({
  server: {
    handlers: {
      POST: ({ request }) => handleCutPlan(request, readPlannerEnv()),
    },
  },
});
