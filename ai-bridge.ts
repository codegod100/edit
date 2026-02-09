#!/usr/bin/env bun
import { generateText, type CoreMessage } from "ai";
import { createOpenAI } from "@ai-sdk/openai";
import { createAnthropic } from "@ai-sdk/anthropic";
import { createGoogleGenerativeAI } from "@ai-sdk/google";
import { z } from "zod";

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
      compatibility: "compatible",
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

async function handleChat(request: any) {
  const messages = request.messages as CoreMessage[];
  const cleanedMessages = messages.map(m => {
    if (typeof m.content === 'string') {
      return { ...m, content: m.content.replace(/\u001b\[[0-9;]*m/g, '') };
    }
    return m;
  });

  console.error(`Chat request with ${cleanedMessages.length} messages. Provider: ${providerId}, Model: ${modelId}`);
  
  try {
    const result = await generateText({
      model: getModel(),
      messages: cleanedMessages,
      tools: tools,
    });
    
    // Attempt to recover args from steps if toolCalls has empty args
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
        // If args is empty object, try fallback
        if (!args || (typeof args === 'object' && Object.keys(args).length === 0)) {
            const fb = fallbackArgs.get(tc.toolCallId);
            if (fb && Object.keys(fb).length > 0) {
                console.error(`Recovered args for ${tc.toolCallId} from steps`);
                args = fb;
            } else {
               // Last ditch: check if 'input' exists on tc (undocumented)
               if ((tc as any).input) {
                   console.error(`Using raw input for ${tc.toolCallId}`);
                   args = (tc as any).input;
               }
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
    // console.error(`Response payload: ${JSON.stringify(response)}`);
    return response;
  } catch (e: any) {
    console.error(`AI SDK Error: ${e.name} - ${e.message}`);
    if (e.data) console.error(`Error data: ${JSON.stringify(e.data)}`);
    return { type: "error", error: e.message };
  }
}

console.log(JSON.stringify({ type: "ready" }));

const reader = Bun.stdin.stream().getReader();
let buffer = "";

while (true) {
  const { value, done } = await reader.read();
  if (done) break;
  
  buffer += new TextDecoder().decode(value);
  const lines = buffer.split("\n");
  buffer = lines.pop() || "";
  
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      const request = JSON.parse(line);
      if (request.type === "chat") {
        const response = await handleChat(request);
        console.log(JSON.stringify(response));
      }
    } catch (e: any) {
      console.error(`Parse Error: ${e.message} (line: ${line})`);
      console.log(JSON.stringify({ type: "error", error: e.message }));
    }
  }
}