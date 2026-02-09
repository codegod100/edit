#!/usr/bin/env bun
import { generateText, type CoreMessage } from "ai";
import { createOpenAI } from "@ai-sdk/openai";
import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { z } from "zod";
import * as readline from "node:readline";

const providerId = process.env.ZAGENT_PROVIDER || "openai";
const modelId = process.env.ZAGENT_MODEL || "gpt-4o";
const apiKey = process.env.ZAGENT_API_KEY || "";

function getModel() {
  if (providerId === "openai") {
    const ai = createOpenAI({ apiKey });
    return ai(modelId);
  } else if (providerId === "anthropic") {
    const ai = createAnthropic({ apiKey });
    return ai(modelId);
  } else if (providerId === "google") {
    const ai = createGoogleGenerativeAI({ apiKey });
    return ai(modelId);
  } else if (providerId === "openrouter") {
    const or = createOpenAI({
      apiKey,
      baseURL: "https://openrouter.ai/api/v1",
    });
    return or(modelId);
  } else if (providerId === "opencode") {
    const oc = createOpenAI({
      apiKey,
      baseURL: "https://opencode.ai/zen/v1",
      compatibility: "compatible",
    });
    return oc(modelId);
  }
  
  const client = createOpenAI({
    apiKey,
    baseURL: process.env.AI_BASE_URL,
  });
  return client(modelId);
}

const tools = {
  bash: {
    description: "Execute a shell command and return stdout.",
    parameters: z.object({
      command: z.string().describe("The shell command to execute"),
    }),
  },
  read_file: {
    description: "Read a file and return its contents. Supports partial reads with offset/limit.",
    parameters: z.object({
      path: z.string().describe("The path to the file to read"),
      offset: z.number().int().optional().describe("Byte offset to start reading from"),
      limit: z.number().int().optional().describe("Maximum bytes to read (default 4096, ~100 lines)"),
    }),
  },
  list_files: {
    description: "List files and directories in a folder.",
    parameters: z.object({
      path: z.string().describe("The directory path to list"),
    }),
  },
  write_file: {
    description: "Write complete file contents to a path.",
    parameters: z.object({
      path: z.string().describe("The path to the file to write"),
      content: z.string().describe("The content to write"),
    }),
  },
  replace_in_file: {
    description: "Replace text in a file. Use unique enough text to match single occurrence.",
    parameters: z.object({
      path: z.string().describe("The path to the file"),
      find: z.string().describe("The exact string to find"),
      replace: z.string().describe("The string to replace it with"),
      all: z.boolean().optional().describe("Replace all occurrences (default false)"),
    }),
  },
  read: {
    description: "Read a file and return its contents. Supports partial reads with offset/limit.",
    parameters: z.object({
      filePath: z.string().describe("The path to the file"),
      offset: z.number().int().optional().describe("Byte offset to start reading from"),
      limit: z.number().int().optional().describe("Maximum bytes to read (default 4096, ~100 lines)"),
    }),
  },
  list: {
    description: "List files in a directory.",
    parameters: z.object({
      path: z.string().describe("The directory path"),
    }),
  },
  write: {
    description: "Write file content.",
    parameters: z.object({
      filePath: z.string().describe("The path to the file"),
      content: z.string().describe("The content to write"),
    }),
  },
  edit: {
    description: "Edit file content.",
    parameters: z.object({
      filePath: z.string().describe("The path to the file"),
      oldString: z.string().describe("The text to find"),
      newString: z.string().describe("The text to replace with"),
    }),
  },
  apply_patch: {
    description: "Apply a structured patch.",
    parameters: z.object({
      patchText: z.string().describe("The patch content"),
    }),
  },
  todo_add: {
    description: "Add a task to the todo list.",
    parameters: z.object({
      description: z.string().describe("The task description"),
    }),
  },
  todo_update: {
    description: "Update a todo status.",
    parameters: z.object({
      id: z.string().describe("The task ID"),
      status: z.string().describe("The new status"),
    }),
  },
  todo_list: {
    description: "List todos.",
    parameters: z.object({}),
  },
};

function normalizeMessages(messages: any[]): CoreMessage[] {
  const toolCallMap = new Map<string, string>();

  return messages.map(m => {
    const role = m.role;
    const content = m.content || '';
    
    if (role === 'assistant') {
      const toolCalls = m.toolCalls || m.tool_calls;
      if (toolCalls && toolCalls.length > 0) {
        const normalizedToolCalls = toolCalls.map((tc: any) => {
          const id = tc.id || tc.toolCallId;
          const name = tc.tool || tc.toolName || (tc.function ? tc.function.name : 'unknown');
          let args = tc.args;
          if (typeof args === 'string') {
            try { args = JSON.parse(args); } catch (e) { args = {}; }
          }
          if (id && name) toolCallMap.set(id, name);
          return { toolCallId: id, toolName: name, args: args || {} };
        });
        return { role: 'assistant', content: content, toolCalls: normalizedToolCalls };
      }
    }

    if (role === 'tool') {
      const toolCallId = m.tool_call_id || m.toolCallId;
      const name = m.tool || m.toolName || toolCallMap.get(toolCallId) || 'unknown';
      return {
        role: 'tool',
        content: [{
          type: 'tool-result',
          toolCallId: toolCallId,
          toolName: name,
          result: content
        }]
      };
    }

    return { role, content };
  }) as CoreMessage[];
}

async function handleChat(request: any) {
  const messages = normalizeMessages(request.messages || []);

  console.error(`Chat request with ${messages.length} messages. Provider: ${providerId}, Model: ${modelId}`);
  
  try {
    const result = await generateText({
      model: getModel(),
      messages: messages,
      tools: tools,
    });
    
    const fallbackArgs = new Map<string, any>();
    if (result.steps) {
       for (const step of result.steps) {
          if (step.toolCalls) {
             for (const tc of step.toolCalls) {
                fallbackArgs.set(tc.toolCallId, tc.args);
             }
          }
       }
    }

    const response = {
      type: "response",
      text: result.text,
      toolCalls: result.toolCalls.map(tc => {
        let args = tc.args;
        if (!args || (typeof args === 'object' && Object.keys(args).length === 0)) {
            const fb = fallbackArgs.get(tc.toolCallId);
            if (fb && Object.keys(fb).length > 0) {
                console.error(`Recovered args for ${tc.toolCallId} from steps`);
                args = fb;
            } else if ((tc as any).input) {
                console.error(`Using raw input for ${tc.toolCallId}`);
                args = (tc as any).input;
            }
        }
        
        return {
          id: tc.toolCallId,
          tool: tc.toolName,
          args: JSON.stringify(args || {}),
        };
      }),
      finishReason: result.finishReason,
    };
    return response;
  } catch (e: any) {
    console.error(`AI SDK Error: ${e.name} - ${e.message}`);
    if (e.data) console.error(`Error data: ${JSON.stringify(e.data)}`);
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
