import {
  LLMHTTPMock,
  buildAnthropicMessage,
  createSSEStream,
  jsonResponse,
} from "./llm.js";

export class AnthropicMock extends LLMHTTPMock {
  constructor(port = 19101) {
    super(port);
    this.messagesHandler = null;
  }

  start() {
    this.on("POST", "/v1/messages", async (req, log) => {
      if (this.messagesHandler) {
        return this.messagesHandler(req, log);
      }

      const body = log.body && typeof log.body === "object" ? log.body : {};
      if (body.stream) {
        return this.streamMessage();
      }
      return this.message();
    });

    return super.start();
  }

  setMessagesHandler(handler) {
    this.messagesHandler = handler;
    return this;
  }

  message(options = {}) {
    return jsonResponse(buildAnthropicMessage(options), 200, {
      "anthropic-version": "2023-06-01",
    });
  }

  messageError({
    status = 401,
    type = "authentication_error",
    message = "mock anthropic error",
  } = {}) {
    return jsonResponse(
      {
        type: "error",
        error: {
          type,
          message,
        },
      },
      status,
      {
        "anthropic-version": "2023-06-01",
      }
    );
  }

  streamMessage({
    model = "claude-3-5-sonnet-20241022",
    events = [
      {
        event: "message_start",
        data: {
          type: "message_start",
          message: {
            id: "msg_mock",
            type: "message",
            role: "assistant",
            model,
            content: [],
            usage: { input_tokens: 12, output_tokens: 0 },
          },
        },
      },
      {
        event: "content_block_delta",
        data: {
          type: "content_block_delta",
          index: 0,
          delta: { type: "text_delta", text: "mock" },
        },
      },
      {
        event: "message_delta",
        data: {
          type: "message_delta",
          delta: { stop_reason: "end_turn" },
          usage: { output_tokens: 7 },
        },
      },
      {
        event: "message_stop",
        data: { type: "message_stop" },
      },
    ],
    delayMs = 0,
    splitStrategy = null,
    omitTerminalNewline = false,
    headers = {},
  } = {}) {
    return new Response(
      createSSEStream(events, { delayMs, splitStrategy, omitTerminalNewline }),
      {
        status: 200,
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache",
          Connection: "keep-alive",
          "anthropic-version": "2023-06-01",
          ...headers,
        },
      }
    );
  }
}

export function createAnthropicMock(port) {
  return new AnthropicMock(port).start();
}
