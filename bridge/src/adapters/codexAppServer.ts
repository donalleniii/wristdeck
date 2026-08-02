import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createRequire } from 'node:module';
import readline from 'node:readline';

type RpcId = string | number;

interface RpcMessage {
  id?: RpcId;
  method?: string;
  params?: any;
  result?: any;
  error?: { code?: number; message?: string };
}

interface PendingRequest {
  resolve(value: any): void;
  reject(error: Error): void;
}

export interface AppServerHandlers {
  notification(method: string, params: any): void;
  request(method: string, params: any): Promise<any>;
  closed(error: Error): void;
}

const require = createRequire(import.meta.url);
const CODEX_CLI = require.resolve('@openai/codex/bin/codex.js');

/**
 * One stdio Codex app-server connection.
 *
 * WristDeck deliberately starts one connection per turn. That keeps concurrent
 * watch turns isolated and makes abort/cleanup deterministic, while persisted
 * Codex thread IDs still provide conversation continuity across connections.
 */
export class CodexAppServer {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly handlers: AppServerHandlers;
  private readonly pending = new Map<RpcId, PendingRequest>();
  private nextId = 1;
  private stderr = '';
  private stopped = false;
  private readonly exited: Promise<void>;

  constructor(handlers: AppServerHandlers) {
    this.handlers = handlers;
    // Spawn through the package entry point so its platform-specific native
    // binary resolution stays owned by @openai/codex rather than duplicated
    // here. Inheriting process.env is required for ~/.codex auth resolution.
    this.child = spawn(process.execPath, [CODEX_CLI, 'app-server', '--listen', 'stdio://'], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    });

    this.child.stderr.setEncoding('utf8');
    this.child.stderr.on('data', (chunk: string) => {
      // App-server can be chatty. Keep only the tail for an actionable crash
      // message without growing memory for a long turn.
      this.stderr = (this.stderr + chunk).slice(-16_000);
    });

    this.exited = new Promise<void>((resolve) => {
      this.child.once('exit', (code, signal) => {
        const detail = signal ? `signal ${signal}` : `code ${code ?? 1}`;
        const suffix = this.stderr.trim() ? `: ${this.stderr.trim()}` : '';
        const error = new Error(`Codex app-server exited with ${detail}${suffix}`);
        for (const request of this.pending.values()) request.reject(error);
        this.pending.clear();
        if (!this.stopped) handlers.closed(error);
        resolve();
      });
    });

    this.child.once('error', (error) => {
      this.failAll(error);
      if (!this.stopped) handlers.closed(error);
    });

    const lines = readline.createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    void (async () => {
      for await (const line of lines) {
        if (!line.trim()) continue;
        let message: RpcMessage;
        try {
          message = JSON.parse(line) as RpcMessage;
        } catch (error) {
          const invalid = new Error(`Invalid JSON from Codex app-server: ${line.slice(0, 240)}`, { cause: error });
          this.failAll(invalid);
          if (!this.stopped) handlers.closed(invalid);
          continue;
        }
        this.receive(message);
      }
    })();
  }

  async initialize(): Promise<void> {
    await this.request('initialize', {
      clientInfo: { name: 'wristdeck', title: 'WristDeck', version: '0.1.0' },
      capabilities: null,
    });
    this.notify('initialized', {});
  }

  request(method: string, params: unknown): Promise<any> {
    const id = this.nextId++;
    const promise = new Promise<any>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
    this.write({ id, method, params });
    return promise;
  }

  notify(method: string, params: unknown): void {
    this.write({ method, params });
  }

  respond(id: RpcId, result: unknown): void {
    this.write({ id, result });
  }

  respondError(id: RpcId, message: string): void {
    this.write({ id, error: { code: -32601, message } });
  }

  async stop(): Promise<void> {
    if (this.stopped) return this.exited;
    this.stopped = true;
    this.child.stdin.end();
    if (!this.child.killed) this.child.kill('SIGTERM');
    await this.exited;
  }

  private receive(message: RpcMessage): void {
    // A method plus an id is a server-initiated request. Handle it without
    // blocking the read loop: approval waits can last minutes while other
    // notifications must continue to flow to the watch.
    if (message.method && message.id !== undefined) {
      void this.handlers.request(message.method, message.params).then(
        (result) => this.respondIfOpen(message.id!, result),
        (error: unknown) => this.respondErrorIfOpen(
          message.id!, error instanceof Error ? error.message : String(error)),
      );
      return;
    }

    if (message.method) {
      this.handlers.notification(message.method, message.params);
      return;
    }

    if (message.id !== undefined) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(message.error.message ?? `Codex RPC error ${message.error.code ?? ''}`));
      } else {
        pending.resolve(message.result);
      }
    }
  }

  private write(message: RpcMessage): void {
    if (this.stopped || this.child.stdin.destroyed) {
      throw new Error('Codex app-server connection is closed');
    }
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  /**
   * A watch approval can settle just after an aborted turn closes app-server.
   * That response is obsolete, so drop it instead of letting write() throw in
   * a detached promise callback and crash the entire WristDeck bridge.
   */
  private respondIfOpen(id: RpcId, result: unknown): void {
    if (this.stopped || this.child.stdin.destroyed) return;
    this.respond(id, result);
  }

  private respondErrorIfOpen(id: RpcId, message: string): void {
    if (this.stopped || this.child.stdin.destroyed) return;
    this.respondError(id, message);
  }

  private failAll(error: Error): void {
    for (const request of this.pending.values()) request.reject(error);
    this.pending.clear();
  }
}
