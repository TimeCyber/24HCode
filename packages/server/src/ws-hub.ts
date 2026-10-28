import type { IncomingMessage, Server as HttpServer } from "node:http";
import { WebSocketServer, WebSocket } from "ws";
import { type WsEvent, type WsEventType, nowIso } from "@codeassist/shared";

type ClientMeta = {
  projectIds: Set<string> | null; // null = all
};

export class WsHub {
  private wss: WebSocketServer | null = null;
  private clients = new Map<WebSocket, ClientMeta>();

  attach(server: HttpServer, authenticate: (token: string | null) => boolean) {
    this.wss = new WebSocketServer({ server, path: "/ws" });

    this.wss.on("connection", (socket, req: IncomingMessage) => {
      const url = new URL(req.url ?? "/ws", "http://localhost");
      const token =
        url.searchParams.get("token") ??
        (req.headers.authorization?.startsWith("Bearer ")
          ? req.headers.authorization.slice(7)
          : null);

      if (!authenticate(token)) {
        socket.close(4401, "unauthorized");
        return;
      }

      this.clients.set(socket, { projectIds: null });

      socket.on("message", (raw) => {
        try {
          const msg = JSON.parse(String(raw)) as {
            type?: string;
            projectIds?: string[];
          };
          if (msg.type === "subscribe") {
            const meta = this.clients.get(socket);
            if (!meta) return;
            meta.projectIds =
              msg.projectIds && msg.projectIds.length > 0
                ? new Set(msg.projectIds)
                : null;
          }
        } catch {
          // ignore malformed
        }
      });

      socket.on("close", () => {
        this.clients.delete(socket);
      });
    });
  }

  broadcast(
    type: WsEventType,
    payload: unknown,
    projectId?: string,
  ) {
    const event: WsEvent = { type, payload, at: nowIso() };
    const data = JSON.stringify(event);
    for (const [socket, meta] of this.clients) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      if (
        projectId &&
        meta.projectIds &&
        !meta.projectIds.has(projectId)
      ) {
        continue;
      }
      socket.send(data);
    }
  }
}
