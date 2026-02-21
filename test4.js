import { streamSimple } from "@mariozechner/pi-ai";
import { registerApiProvider } from "@mariozechner/pi-ai";
import { streamOpenAiCompletions, streamSimpleOpenAiCompletions } from "@mariozechner/pi-ai/dist/providers/openai-completions.js";

registerApiProvider({
    api: "openai-completions",
    stream: streamOpenAiCompletions,
    streamSimple: streamSimpleOpenAiCompletions,
});

async function main() {
  const context = {
    systemPrompt: "You are a helpful assistant.",
    messages: [{ role: "user", content: [{ type: "text", text: "test" }] }],
    tools: []
  };

  const model = {
    id: "zai-org/GLM-5",
    provider: "deepinfra",
    api: "openai-completions",
    baseUrl: "https://api.deepinfra.com/v1/openai",
    reasoning: true,
    maxTokens: 65536
  };

  try {
    const stream = streamSimple(model, context, {
      apiKey: process.env.DEEPINFRA_TOKEN
    });

    for await (const chunk of stream) {
        console.log(chunk);
    }
  } catch (e) {
    console.error("Error:", e);
  }
}
main();
