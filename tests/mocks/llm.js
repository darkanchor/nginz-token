function jsonResponse(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...headers,
    },
  });
}

function textResponse(body, status = 200, headers = {}) {
  return new Response(body, {
    status,
    headers,
  });
}

function encodeSSEEvent(event) {
  if (typeof event === "string") return event;

  const lines = [];

  if (event.comment) {
    lines.push(`: ${event.comment}`);
  }
  if (event.event) {
    lines.push(`event: ${event.event}`);
  }
  if (event.id) {
    lines.push(`id: ${event.id}`);
  }

  const data = event.data;
  if (data !== undefined) {
    const payload =
      typeof data === "string" ? data : JSON.stringify(data);
    for (const line of payload.split("\n")) {
      lines.push(`data: ${line}`);
    }
  }

  return `${lines.join("\n")}\n\n`;
}

function splitChunk(chunk, splitAt = []) {
  if (!splitAt.length) return [chunk];

  const parts = [];
  let cursor = 0;
  for (const boundary of splitAt) {
    const point = Math.max(cursor, Math.min(boundary, chunk.length));
    parts.push(chunk.slice(cursor, point));
    cursor = point;
  }
  parts.push(chunk.slice(cursor));
  return parts.filter((part) => part.length > 0);
}

export function createSSEStream(events, options = {}) {
  const {
    delayMs = 0,
    splitStrategy = null,
    omitTerminalNewline = false,
  } = options;

  const chunks = [];
  events.forEach((event, index) => {
    let encoded = encodeSSEEvent(event);
    if (omitTerminalNewline && index === events.length - 1) {
      encoded = encoded.replace(/\n\n$/, "\n");
    }

    if (splitStrategy) {
      const boundaries =
        typeof splitStrategy === "function"
          ? splitStrategy(encoded, index, event) || []
          : [];
      chunks.push(...splitChunk(encoded, boundaries));
    } else {
      chunks.push(encoded);
    }
  });

  return new ReadableStream({
    async start(controller) {
      for (const chunk of chunks) {
        if (delayMs > 0) {
          await Bun.sleep(delayMs);
        }
        controller.enqueue(new TextEncoder().encode(chunk));
      }
      controller.close();
    },
  });
}

export class LLMHTTPMock {
  constructor(port, options = {}) {
    this.port = port;
    this.server = null;
    this.requestLog = [];
    this.defaultHeaders = options.defaultHeaders || {};
    this.routes = new Map();
  }

  start() {
    this.server = Bun.serve({
      port: this.port,
      fetch: (req) => this.handle(req),
    });
    return this;
  }

  stop() {
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
    this.requestLog = [];
    this.routes.clear();
  }

  on(method, path, handler) {
    this.routes.set(`${method.toUpperCase()} ${path}`, handler);
    return this;
  }

  getRequests() {
    return [...this.requestLog];
  }

  getRequestsFor(path, method = undefined) {
    return this.requestLog.filter(
      (entry) =>
        entry.path === path &&
        (method === undefined || entry.method === method.toUpperCase())
    );
  }

  async handle(req) {
    const url = new URL(req.url);
    const logEntry = {
      method: req.method,
      path: url.pathname,
      query: Object.fromEntries(url.searchParams),
      headers: Object.fromEntries(req.headers),
      timestamp: Date.now(),
      body: null,
    };

    if (req.method !== "GET" && req.method !== "HEAD") {
      try {
        const contentType = req.headers.get("content-type") || "";
        if (contentType.includes("application/json")) {
          logEntry.body = await req.clone().json();
        } else {
          logEntry.body = await req.clone().text();
        }
      } catch {
        logEntry.body = null;
      }
    }

    this.requestLog.push(logEntry);
    const route = this.routes.get(`${req.method.toUpperCase()} ${url.pathname}`);
    if (!route) {
      return jsonResponse(
        { error: `${req.method} ${url.pathname} not mocked` },
        404
      );
    }

    return route(req, logEntry);
  }
}

export function buildOpenAIChatCompletion({
  id = "chatcmpl-mock",
  model = "gpt-4o-mini",
  content = "mock response",
  finishReason = "stop",
  usage = {
    prompt_tokens: 12,
    completion_tokens: 7,
    total_tokens: 19,
  },
  extra = {},
} = {}) {
  return {
    id,
    object: "chat.completion",
    model,
    choices: [
      {
        index: 0,
        finish_reason: finishReason,
        message: {
          role: "assistant",
          content,
        },
      },
    ],
    usage,
    ...extra,
  };
}

export function buildAnthropicMessage({
  id = "msg_mock",
  model = "claude-3-5-sonnet-20241022",
  text = "mock response",
  stopReason = "end_turn",
  usage = {
    input_tokens: 12,
    output_tokens: 7,
  },
  extra = {},
} = {}) {
  return {
    id,
    type: "message",
    role: "assistant",
    model,
    content: [{ type: "text", text }],
    stop_reason: stopReason,
    usage,
    ...extra,
  };
}

export { jsonResponse, textResponse };
