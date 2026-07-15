import {
  LLMHTTPMock,
  buildOpenAIChatCompletion,
  createSSEStream,
  jsonResponse,
} from "./llm.js";

export class OpenAIMock extends LLMHTTPMock {
  constructor(port = 19100) {
    super(port);
    this.chatCompletionHandler = null;
    this.modelsHandler = null;
  }

  start() {
    this.on("GET", "/v1/models", (_req, _log) => {
      if (this.modelsHandler) return this.modelsHandler();
      return jsonResponse({
        object: "list",
        data: [{ id: "gpt-4o-mini", object: "model" }],
      });
    });

    this.on("POST", "/v1/chat/completions", async (req, log) => {
      if (this.chatCompletionHandler) {
        return this.chatCompletionHandler(req, log);
      }

      const body = log.body && typeof log.body === "object" ? log.body : {};
      if (body.stream) {
        return this.streamChatCompletion();
      }
      return this.chatCompletion();
    });

    return super.start();
  }

  setModelsHandler(handler) {
    this.modelsHandler = handler;
    return this;
  }

  setChatCompletionHandler(handler) {
    this.chatCompletionHandler = handler;
    return this;
  }

  chatCompletion(options = {}) {
    return jsonResponse(buildOpenAIChatCompletion(options));
  }

  chatCompletionError({
    status = 401,
    message = "mock openai error",
    type = "invalid_request_error",
    code = null,
  } = {}) {
    return jsonResponse(
      {
        error: {
          message,
          type,
          code,
        },
      },
      status
    );
  }

  streamChatCompletion({
    model = "gpt-4o-mini",
    chunks = [
      {
        data: {
          id: "chatcmpl-mock",
          object: "chat.completion.chunk",
          model,
          choices: [{ index: 0, delta: { role: "assistant" } }],
        },
      },
      {
        data: {
          id: "chatcmpl-mock",
          object: "chat.completion.chunk",
          model,
          choices: [{ index: 0, delta: { content: "mock" } }],
        },
      },
      {
        data: {
          id: "chatcmpl-mock",
          object: "chat.completion.chunk",
          model,
          choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
          usage: {
            prompt_tokens: 12,
            completion_tokens: 7,
            total_tokens: 19,
          },
        },
      },
      { data: "[DONE]" },
    ],
    delayMs = 0,
    splitStrategy = null,
    omitTerminalNewline = false,
    headers = {},
  } = {}) {
    return new Response(
      createSSEStream(chunks, { delayMs, splitStrategy, omitTerminalNewline }),
      {
        status: 200,
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
          ...headers,
        },
      }
    );
  }
}

export function createOpenAIMock(port) {
  return new OpenAIMock(port).start();
}
