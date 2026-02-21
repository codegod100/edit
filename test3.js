import { OpenAI } from "openai";
const client = new OpenAI({
  baseURL: "https://api.deepinfra.com/v1/openai",
  apiKey: process.env.DEEPINFRA_TOKEN
});
async function main() {
  const stream = await client.chat.completions.create({
    model: "zai-org/GLM-5",
    messages: [{role: "user", content: "test"}],
    stream: true
  });
  for await (const chunk of stream) {
    process.stdout.write(chunk.choices[0]?.delta?.content || "");
  }
}
main();
