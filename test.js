import { OpenAI } from "openai";
const client = new OpenAI({
  baseURL: "https://api.deepinfra.com/v1/openai",
  apiKey: process.env.DEEPINFRA_TOKEN
});
async function main() {
  try {
    const res = await client.chat.completions.create({
      model: "zai-org/GLM-5",
      messages: [{role: "user", content: "test"}]
    });
    console.log(res);
  } catch (e) {
    console.error(e);
  }
}
main();
