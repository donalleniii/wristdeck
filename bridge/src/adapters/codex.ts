import { basename, isAbsolute, resolve } from 'node:path';
import type { AgentAdapter, TurnOutcome, TurnRequest, TurnSink } from './types.ts';
import { CodexAppServer } from './codexAppServer.ts';

// App-server supports real developer instructions, unlike the automation SDK.
// Keeping this out of the user message also keeps session labels and resumption
// history clean.
const DEVELOPER_INSTRUCTIONS =
  'You are running headless on a Mac, driven from an Apple Watch. Your sandbox ' +
  'does not have unattended network or Mac application access.\n' +
  'To show the user a file or folder, call the wristdeck-tools `open_path` tool ' +
  'with the path. Never use shell `open`, `open -a`, `qlmanage`, or `osascript` ' +
  'for this: they fail in the sandbox and can crash the app you are targeting.\n' +
  'To present a web app that needs a local server, do not leave `npm run dev` or ' +
  'another server running through the command tool: it will be stopped when this ' +
  'turn ends. After the app and its tests are ready, call the wristdeck-tools ' +
  '`launch_preview` tool with the absolute project path, loopback URL, package ' +
  'script, and a short expectedText check. That tool keeps the server alive, ' +
  'verifies the page, and opens it in the Mac browser. Do not use browser ' +
  'automation to present the result from this headless client. Only say a preview ' +
  'is running after `launch_preview` succeeds.\n' +
  'If an action genuinely needs more permission, make one normal permission ' +
  'request so WristDeck can show it on the watch. Never evade the sandbox. If ' +
  'permission is denied, continue every safe part of the task instead of ' +
  'abandoning the whole result.\n' +
  'For a local website preview, prefer a self-contained static artifact (or a ' +
  'static build) that open_path can open directly. Do not make a long-running ' +
  'development server a prerequisite when opening the HTML file is sufficient.\n' +
  'Work through recoverable tool failures and continue until the requested ' +
  'deliverable is actually complete.';

export class CodexAdapter implements AgentAdapter {
  async runTurn(req: TurnRequest, sink: TurnSink, signal: AbortSignal): Promise<TurnOutcome> {
    let threadId = '';
    let appTurnId = '';
    let completedBeforeStart: any = null;
    let resolveCompletion!: (value: any) => void;
    let rejectCompletion!: (error: Error) => void;
    const completion = new Promise<any>((resolveCompletionPromise, rejectCompletionPromise) => {
      resolveCompletion = resolveCompletionPromise;
      rejectCompletion = rejectCompletionPromise;
    });
    const phases = new Map<string, string | null>();
    const streamed = new Set<string>();
    const finalTexts: string[] = [];
    const fallbackTexts: string[] = [];
    let presented = false;

    const server = new CodexAppServer({
      notification: (method, params) => {
        if (method === 'turn/completed') {
          const turn = params?.turn;
          if (!appTurnId || turn?.id === appTurnId) {
            if (appTurnId) resolveCompletion(turn);
            else completedBeforeStart = turn;
          }
          return;
        }
        if (params?.turnId && appTurnId && params.turnId !== appTurnId) return;

        if (method === 'turn/started') {
          // Codex can take several seconds before its first real item. Without
          // this, the watch looks hung even though the turn is healthy.
          sink.push({ type: 'status', label: 'Starting Codex' });
        } else if (method === 'item/started') {
          const item = params?.item;
          if (typeof item?.id === 'string' && item.type === 'agentMessage') {
            phases.set(item.id, typeof item.phase === 'string' ? item.phase : null);
          }
          pushStartedStatus(item, sink);
        } else if (method === 'item/agentMessage/delta') {
          const delta = params?.delta;
          if (typeof params?.itemId === 'string') streamed.add(params.itemId);
          if (typeof delta === 'string' && delta) sink.push({ type: 'text', chunk: delta });
        } else if (method === 'item/completed') {
          const item = params?.item;
          if (item?.type === 'agentMessage' && typeof item.text === 'string' && item.text) {
            fallbackTexts.push(item.text);
            const phase = item.phase ?? phases.get(item.id) ?? null;
            if (phase === 'final_answer') finalTexts.push(item.text);
            if (!streamed.has(item.id)) sink.push({ type: 'text', chunk: item.text });
          }
          if (noteCompletedItem(item, req, sink)) presented = true;
        } else if (method === 'error') {
          const message = params?.error?.message ?? params?.message;
          if (typeof message === 'string') {
            sink.push({ type: 'status', label: `Error: ${message.slice(0, 60)}` });
          }
        } else if (method === 'warning' && typeof params?.message === 'string') {
          sink.push({ type: 'status', label: params.message.slice(0, 60) });
        }
      },
      request: (method, params) => handleApproval(method, params, req),
      closed: (error) => rejectCompletion(error),
    });

    const onAbort = (): void => {
      // TurnStore marks the watch turn stopped immediately. Also wake this
      // adapter's completion wait so the detached task and app-server process
      // cannot linger in the background after that UI state has cleared.
      rejectCompletion(new Error('Codex turn was stopped'));
      if (threadId && appTurnId) {
        void server.request('turn/interrupt', { threadId, turnId: appTurnId })
          .catch(() => undefined);
      }
      void server.stop();
    };
    if (signal.aborted) onAbort();
    else signal.addEventListener('abort', onAbort, { once: true });

    try {
      if (signal.aborted) throw new Error('Codex turn aborted');
      await server.initialize();
      const threadResult = await server.request(req.sessionId ? 'thread/resume' : 'thread/start', {
        ...(req.sessionId ? { threadId: req.sessionId } : {}),
        ...(req.cwd ? { cwd: req.cwd } : {}),
        ...(req.model ? { model: req.model } : {}),
        approvalPolicy: 'on-request',
        approvalsReviewer: 'user',
        sandbox: 'workspace-write',
        developerInstructions: DEVELOPER_INSTRUCTIONS,
      });
      threadId = String(threadResult?.thread?.id ?? '');
      if (!threadId) throw new Error('Codex app-server did not return a thread id');
      sink.push({ type: 'session', agent: 'codex', sessionId: threadId });
      sink.push({ type: 'model', name: String(threadResult?.model ?? req.model ?? 'default') });

      const turnResult = await server.request('turn/start', {
        threadId,
        input: [{ type: 'text', text: req.text, text_elements: [] }],
      });
      appTurnId = String(turnResult?.turn?.id ?? '');
      if (!appTurnId) throw new Error('Codex app-server did not return a turn id');
      if (completedBeforeStart?.id === appTurnId) resolveCompletion(completedBeforeStart);

      const finished = await completion;
      if (finished?.status === 'failed') {
        throw new Error(finished?.error?.message ?? 'Codex turn failed');
      }
      if (finished?.status === 'interrupted') throw new Error('Codex turn was stopped');
      return {
        fullText: (finalTexts.length ? finalTexts : fallbackTexts).join('\n\n'),
        presented,
      };
    } finally {
      signal.removeEventListener('abort', onAbort);
      await server.stop();
    }
  }
}

function pushStartedStatus(item: any, sink: TurnSink): void {
  if (item?.type === 'commandExecution') {
    sink.push({ type: 'status', label: `Running ${String(item.command ?? '').slice(0, 40)}` });
  } else if (item?.type === 'fileChange') {
    const changes = Array.isArray(item.changes) ? item.changes : [];
    const n = changes.length || 1;
    const name = changes.length === 1 && typeof changes[0]?.path === 'string'
      ? basename(changes[0].path)
      : `${n} file${n === 1 ? '' : 's'}`;
    sink.push({ type: 'status', label: `Editing ${name}` });
  } else if (item?.type === 'reasoning') {
    sink.push({ type: 'status', label: 'Thinking' });
  } else if (item?.type === 'plan') {
    sink.push({ type: 'status', label: 'Planning' });
  } else if (item?.type === 'webSearch') {
    sink.push({ type: 'status', label: 'Searching the web' });
  } else if (item?.type === 'mcpToolCall') {
    sink.push({ type: 'status', label: `Using ${String(item.tool ?? 'a tool')}` });
  }
}

function noteCompletedItem(item: any, req: TurnRequest, sink: TurnSink): boolean {
  if (item?.type === 'fileChange' && Array.isArray(item.changes)) {
    for (const change of item.changes) {
      if (typeof change?.path !== 'string' || !change.path) continue;
      req.noteTouched?.(isAbsolute(change.path) ? change.path : resolve(req.cwd ?? '', change.path));
    }
  } else if (item?.type === 'mcpToolCall') {
    if (item.server === 'wristdeck-tools' && item.tool === 'open_path' && typeof item.arguments?.path === 'string') {
      req.noteTouched?.(item.arguments.path);
    }
    if (item.status === 'failed' && typeof item.error?.message === 'string') {
      sink.push({ type: 'status', label: `Tool failed: ${item.error.message.slice(0, 48)}` });
    }
    if (
      item.server === 'wristdeck-tools' &&
      (item.tool === 'open_path' || item.tool === 'launch_preview') &&
      item.status !== 'failed'
    ) {
      return true;
    }
  } else if (item?.type === 'commandExecution' && item.status === 'failed') {
    const code = typeof item.exitCode === 'number' ? ` (exit ${item.exitCode})` : '';
    sink.push({ type: 'status', label: `Command failed${code}` });
  }
  return false;
}

async function handleApproval(method: string, params: any, req: TurnRequest): Promise<any> {
  if (!req.requestApproval || !req.turnId) return declineFor(method, params);

  if (method === 'item/commandExecution/requestApproval') {
    const command = String(params?.command ?? 'Command requiring extra access');
    const reason = String(params?.reason ?? 'needs permission outside the normal sandbox');
    const outcome = await req.requestApproval(req.turnId, {
      tool: 'Codex command',
      summary: shortSummary(params?.reason, `Run ${command}`),
      detail: command,
      cwd: String(params?.cwd ?? req.cwd ?? ''),
      risk: params?.networkApprovalContext ? 'network access' : reason,
    });
    return { decision: outcome === 'allow' ? 'accept' : outcome === 'timeout' ? 'cancel' : 'decline' };
  }

  if (method === 'item/fileChange/requestApproval') {
    const root = String(params?.grantRoot ?? req.cwd ?? 'another folder');
    const outcome = await req.requestApproval(req.turnId, {
      tool: 'Codex file change',
      summary: shortSummary(params?.reason, `Write outside ${basename(req.cwd ?? 'the project')}`),
      detail: root,
      cwd: req.cwd ?? '',
      risk: 'writes outside the project',
    });
    return { decision: outcome === 'allow' ? 'accept' : outcome === 'timeout' ? 'cancel' : 'decline' };
  }

  if (method === 'item/permissions/requestApproval') {
    const permissions = params?.permissions ?? {};
    const detail = JSON.stringify(permissions);
    const wantsNetwork = permissions?.network?.enabled === true;
    const outcome = await req.requestApproval(req.turnId, {
      tool: 'Codex permission',
      summary: shortSummary(params?.reason, wantsNetwork ? 'Allow network for this turn' : 'Allow extra file access'),
      detail: detail.length > 500 ? `${detail.slice(0, 497)}...` : detail,
      cwd: String(params?.cwd ?? req.cwd ?? ''),
      risk: wantsNetwork ? 'network access' : 'outside the project',
    });
    return {
      permissions: outcome === 'allow' ? requestedPermissions(permissions) : {},
      scope: 'turn',
      strictAutoReview: false,
    };
  }

  if (method === 'item/tool/requestUserInput') {
    const questions = Array.isArray(params?.questions) ? params.questions : [];
    // App/MCP side-effect confirmation is currently expressed as a one-question
    // Accept/Decline form. The watch has a safer binary approval card, so map
    // that exact shape. Do not guess an answer to ordinary clarification forms.
    const choices = questions.map((question: any) => {
      const options = Array.isArray(question?.options) ? question.options : [];
      const allow = options.find((option: any) => /^(accept|allow|approve|yes)$/i.test(String(option?.label ?? '')));
      const deny = options.find((option: any) => /^(decline|deny|cancel|no)$/i.test(String(option?.label ?? '')));
      return { question, allow, deny };
    });
    if (!choices.length || choices.some((choice: any) => !choice.allow || !choice.deny)) {
      throw new Error('This Codex question needs a full-size client; WristDeck only supports Allow or Deny');
    }
    const detail = choices.map((choice: any) => String(choice.question?.question ?? '')).join('\n');
    const outcome = await req.requestApproval(req.turnId, {
      tool: 'Codex tool',
      summary: shortSummary(choices[0]?.question?.question, 'Allow the requested Codex tool'),
      detail,
      cwd: req.cwd ?? '',
      risk: 'external tool',
    });
    const answers: Record<string, { answers: string[] }> = {};
    for (const choice of choices) {
      const selected = outcome === 'allow' ? choice.allow.label : choice.deny.label;
      answers[String(choice.question.id)] = { answers: [String(selected)] };
    }
    return { answers };
  }

  // WristDeck does not yet render arbitrary multi-question forms or MCP OAuth
  // elicitations. Fail closed instead of leaving the Codex turn parked forever.
  throw new Error(`WristDeck cannot answer Codex request ${method} from the watch yet`);
}

function declineFor(method: string, params: any): any {
  if (method === 'item/permissions/requestApproval') {
    return { permissions: {}, scope: 'turn', strictAutoReview: false };
  }
  if (method === 'item/commandExecution/requestApproval' || method === 'item/fileChange/requestApproval') {
    return { decision: 'decline' };
  }
  throw new Error(`Unsupported Codex request: ${method} (${String(params?.itemId ?? '')})`);
}

function requestedPermissions(requested: any): any {
  const granted: any = {};
  if (requested?.network != null) granted.network = requested.network;
  if (requested?.fileSystem != null) granted.fileSystem = requested.fileSystem;
  return granted;
}

function shortSummary(reason: unknown, fallback: string): string {
  const text = typeof reason === 'string' && reason.trim() ? reason.trim() : fallback;
  return text.length > 90 ? `${text.slice(0, 87)}...` : text;
}
