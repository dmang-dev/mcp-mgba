import net from "net";

export interface RpcRequest {
  id: number;
  method: string;
  params?: Record<string, unknown>;
}

export interface RpcResponse {
  id: number | null;
  result?: unknown;
  error?: { code: number; message: string };
}

export class MgbaClient {
  private socket: net.Socket | null = null;
  private pending = new Map<number, (res: RpcResponse) => void>();
  private nextId = 1;
  private buf = "";
  private connectPromise: Promise<void> | null = null;

  constructor(
    private readonly host: string = "127.0.0.1",
    private readonly port: number = 8765,
  ) {}

  connect(): Promise<void> {
    if (this.connectPromise) return this.connectPromise;
    this.connectPromise = new Promise((resolve, reject) => {
      const sock = net.createConnection({ host: this.host, port: this.port });
      sock.setEncoding("utf8");

      sock.once("connect", () => {
        this.socket = sock;
        resolve();
      });

      sock.once("error", (err) => {
        this.connectPromise = null;
        reject(err);
      });

      sock.on("data", (chunk: string) => {
        this.buf += chunk;
        let nl: number;
        while ((nl = this.buf.indexOf("\n")) !== -1) {
          const line = this.buf.slice(0, nl).trim();
          this.buf = this.buf.slice(nl + 1);
          if (line.length === 0) continue;
          let resp: RpcResponse;
          try {
            resp = JSON.parse(line) as RpcResponse;
          } catch {
            continue;
          }
          if (resp.id != null) {
            const cb = this.pending.get(resp.id);
            if (cb) {
              this.pending.delete(resp.id);
              cb(resp);
            }
          }
        }
      });

      sock.on("close", () => {
        this.socket = null;
        this.connectPromise = null;
        // Reject all in-flight calls
        for (const cb of this.pending.values()) {
          cb({ id: null, error: { code: -1, message: "connection closed" } });
        }
        this.pending.clear();
      });
    });
    return this.connectPromise;
  }

  disconnect(): void {
    this.socket?.destroy();
    this.socket = null;
    this.connectPromise = null;
  }

  get connected(): boolean {
    return this.socket !== null && !this.socket.destroyed;
  }

  async call<T = unknown>(
    method: string,
    params?: Record<string, unknown>,
  ): Promise<T> {
    // Lazy (re)connect — bridge.lua reloads kill the socket, and the user
    // shouldn't have to restart the MCP host every time they edit the script.
    if (!this.socket || this.socket.destroyed) {
      try {
        await this.connect();
      } catch (err) {
        throw new Error(
          `Cannot reach mGBA bridge at ${this.host}:${this.port}. ` +
          `Make sure mGBA is running with bridge.lua loaded (Tools > Scripting). ` +
          `Underlying error: ${(err as Error).message}`,
        );
      }
    }

    return new Promise<T>((resolve, reject) => {
      const sock = this.socket;
      if (!sock) {
        reject(new Error("socket vanished after connect"));
        return;
      }

      const id = this.nextId++;
      this.pending.set(id, (resp) => {
        if (resp.error) {
          reject(new Error(`mGBA RPC error [${resp.error.code}]: ${resp.error.message}`));
        } else {
          resolve(resp.result as T);
        }
      });

      const msg = JSON.stringify({ id, method, params: params ?? {} }) + "\n";
      sock.write(msg, (err) => {
        if (err) {
          this.pending.delete(id);
          reject(err);
        }
      });
    });
  }
}
