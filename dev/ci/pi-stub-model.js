// A scripted model for the smoke test (.github/workflows/dev-smoke.yml), loaded with
// `pi -e /tmp/pi-stub-model.js --model smoke/stub`. Never in the image, never on zero.
//
// Why it exists: pi's permission gate decides on the MODEL's tool call, so a check of the gate
// needs a model that makes one, and the runner has no key and should need no network. This
// serves OpenAI's chat-completions stream on 127.0.0.1 from inside pi's own process (an
// ephemeral port, unref'd, so it ends with pi) and registers it as provider `smoke`. Everything
// else in the run is the container's own: the agent dir, the packages, the gate's config.
//
// Its script: a request that offers a `bash` tool and holds no tool result yet is answered
// with one bash call, $PI_SMOKE_COMMAND; anything else (the tool result coming back) is
// answered "done". $PI_SMOKE_TOOL and $PI_SMOKE_ARGS (a JSON object) make the one call to
// another tool instead, `write` for the write checks.
import http from "node:http";

export default async function (pi) {
  const tool = process.env.PI_SMOKE_TOOL || "bash";
  const args =
    tool === "bash"
      ? JSON.stringify({ command: process.env.PI_SMOKE_COMMAND || "true" })
      : process.env.PI_SMOKE_ARGS || "{}";
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let messages = [];
      let tools = [];
      try {
        const j = JSON.parse(body);
        messages = j.messages || [];
        tools = (j.tools || []).map((t) => t.function && t.function.name);
      } catch {}
      const done = messages.some((m) => m.role === "tool") || !tools.includes(tool);
      const delta = done
        ? { role: "assistant", content: "done" }
        : {
            role: "assistant",
            tool_calls: [
              {
                index: 0,
                id: "call_smoke",
                type: "function",
                function: { name: tool, arguments: args },
              },
            ],
          };
      const chunk = (d, finish) =>
        `data: ${JSON.stringify({
          id: "smoke",
          object: "chat.completion.chunk",
          created: 0,
          model: "stub",
          choices: [{ index: 0, delta: d, finish_reason: finish }],
        })}\n\n`;
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write(chunk(delta, null));
      res.write(chunk({}, done ? "stop" : "tool_calls"));
      res.end("data: [DONE]\n\n");
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  server.unref();
  pi.registerProvider("smoke", {
    name: "smoke stub",
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
    apiKey: "smoke",
    api: "openai-completions",
    models: [
      {
        id: "stub",
        name: "stub",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 32000,
        maxTokens: 1000,
      },
    ],
  });
}
