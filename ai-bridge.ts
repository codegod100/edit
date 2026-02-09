#!/usr/bin/env bun
import OpenAI from "openai";
import * as readline from "node:readline";

const providerId = process.env.ZAGENT_PROVIDER || "openai";
const modelId = process.env.ZAGENT_MODEL || "gpt-4o";
const apiKey = process.env.ZAGENT_API_KEY || "";

const openai = new OpenAI({
  apiKey: apiKey,
  baseURL: providerId === "openrouter" ? "https://openrouter.ai/api/v1" : 
           providerId === "opencode" ? "https://opencode.ai/zen/v1" : undefined
});

async function handleChat(request: any) {
  const messages = (request.messages || []).map((m: any) => {
    const role = m.role;
    let content = m.content || '';
    if (typeof content === 'string') {
      content = content.replace(/\u001b\[[0-9;]*m/g, '');
    }
    
    const out: any = { role, content };
    if (role === 'assistant' && (m.tool_calls || m.toolCalls)) {
      out.tool_calls = (m.tool_calls || m.toolCalls).map((tc: any) => ({
        id: tc.id || tc.toolCallId,
        type: 'function',
        function: {
          name: tc.tool || tc.toolName || (tc.function ? tc.function.name : ''),
          arguments: typeof tc.args === 'string' ? tc.args : JSON.stringify(tc.args || (tc.function ? tc.function.arguments : {}))
        }
      }));
    }
    if (role === 'tool') {
      out.tool_call_id = m.tool_call_id || m.toolCallId;
    }
    return out;
  });

  console.error(`Chat request with ${messages.length} messages. Provider: ${providerId}, Model: ${modelId}`);
  
  try {
    const completion = await openai.chat.completions.create({
      model: modelId,
      messages: messages,
      tools: [
        {
          type: "function",
          function: {
            name: "bash",
            description: "Execute a shell command and return stdout.",
            parameters: {
              type: "object",
              properties: { command: { type: "string" } },
              required: ["command"]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "read_file",
            description: "Read a file and return its contents.",
            parameters: {
              type: "object",
              properties: { 
                path: { type: "string" },
                file_path: { type: "string" },
                file_name: { type: "string" },
                offset: { type: "integer" },
                limit: { type: "integer" }
              }
            }
          }
        },
        {
          type: "function",
          function: {
            name: "write_file",
            description: "Write content to a file.",
            parameters: {
              type: "object",
              properties: { 
                path: { type: "string" },
                file_path: { type: "string" },
                content: { type: "string" }
              },
              required: ["content"]
            }
          }
        },
        {
          type: "function",
          function: {
            name: "replace_in_file",
            description: "Replace text in a file.",
            parameters: {
              type: "object",
              properties: { 
                path: { type: "string" },
                file_path: { type: "string" },
                find: { type: "string" },
                old: { type: "string" },
                replace: { type: "string" },
                new: { type: "string" },
                all: { type: "boolean" }
              }
            }
          }
        },
        {
          type: "function",
          function: {
            name: "todo_list",
            description: "List todos.",
            parameters: { type: "object", properties: {} }
          }
        }
      ],
    });

    const choice = completion.choices[0];
    const message = choice.message;

    const response = {
      type: "response",
      text: message.content || "",
      toolCalls: (message.tool_calls || []).map(tc => ({
        id: tc.id,
        tool: tc.function.name,
        args: tc.function.arguments,
      })),
      finishReason: choice.finish_reason,
    };
    return response;
  } catch (e: any) {
    console.error(`OpenAI Error: ${e.message}`);
    return { type: "error", err: e.message };
  }
}

console.log(JSON.stringify({ type: "ready" }));

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

rl.on('line', async (line) => {
  if (!line.trim()) return;
  console.error(`Received payload: ${line.length} bytes`);
  try {
    const request = JSON.parse(line);
    if (request.type === "chat") {
      const response = await handleChat(request);
      console.log(JSON.stringify(response));
    }
  } catch (e: any) {
    console.error(`Parse Error: ${e.message} (line length: ${line.length})`);
    console.log(JSON.stringify({ type: "error", err: e.message }));
  }
});