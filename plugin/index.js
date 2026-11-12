/**
 * factory-orchestrator — replace headless-runner: dummy parent Agent + Claude Code
 * (or later OpenCode ACP) via ctx.subagents.startActivation. No DSH model call.
 *
 * Pinned against DSH 0.2.1-rc.5 internal APIs (design.md §11).
 */
import { randomUUID } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import z from '@deepseek-ai/schemastery'
import { brandString } from '@deepseek-ai/dsh-brand'
import { resolveTimeoutMs, exitCodeFor } from './step-timeout.js'

export const name = 'factory-orchestrator'

// plugin/index.js → repo root. FACTORY_ROOT from factory-step wins; this fallback
// is the checkout that contains the plugin (original host: /workspace/factory).
const FACTORY_ROOT = process.env.FACTORY_ROOT
  || path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

/** Core services required before the one-shot activation can start. */
export const inject = ['agents', 'subagents']

export const Config = z.object({
  /** Task text; may be supplied by headlessStartup via patch !!js. */
  task: z.string(),
  /** When true, stdout is one JSON object { stopReason, output, diagnostic? }. */
  json: z.boolean().default(false),
  /** Subagent provider registry name (default claude-code). */
  provider: z.string().default('claude-code'),
  /** Working directory; default process.cwd() / mounted fs. */
  cwd: z.string(),
  /** Per-step timeout in ms (default 30 minutes). */
  timeoutMs: z.number().default(30 * 60 * 1000),
  /** Dummy parent AgentOptions.provider — never called when only CC runs. */
  dummyProvider: z.string().default('deepseek-official'),
  /** Dummy parent AgentOptions.model — never called when only CC runs. */
  dummyModel: z.string().default('deepseek-flash'),
  /** Optional short label for the activation. */
  label: z.string().default('factory-step'),
})

function textFromOutput(output) {
  if (!Array.isArray(output)) return ''
  return output
    .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('')
}

/**
 * Best-effort agmsg progress line. Requires FACTORY_AGMSG_TEAM + join already done.
 * Leaves a stderr TODO when unset — full wiring is a later factory concern.
 */
function agmsgProgress(phase, detail) {
  const body = `[factory] ${phase}: ${detail}`
  // Always append to local progress log (no secrets).
  try {
    const dir = process.env.FACTORY_AGMSG_LOG_DIR || path.join(FACTORY_ROOT, 'local/logs')
    spawnSync('bash', ['-lc', `mkdir -p "${dir}" && echo "$(date -Iseconds) ${body.replace(/"/g, '\\"')}" >> "${dir}/agmsg-progress.log"`], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: process.env,
    })
  } catch { /* ignore */ }
  const team = process.env.FACTORY_AGMSG_TEAM
  if (!team) return
  const from = process.env.FACTORY_AGMSG_FROM || 'factory'
  const to = process.env.FACTORY_AGMSG_TO || 'factory'
  const scripts = process.env.FACTORY_AGMSG_SCRIPTS || `${process.env.HOME}/.agents/skills/agmsg/scripts`
  const send = `${scripts}/send.sh`
  const t0 = Date.now()
  let status = 1
  try {
    const r = spawnSync('bash', [send, team, from, to, body, '--force'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: process.env,
    })
    status = typeof r.status === 'number' ? r.status : 1
  } catch {
    // Progress is advisory; never fail the step on agmsg errors.
  }
  // Usage: send count/duration (local/usage/<date>/agmsg.jsonl). Best effort.
  try {
    const root = FACTORY_ROOT
    spawnSync(`${root}/bin/factory-usage`, ['agmsg-send', '--duration-ms', String(Date.now() - t0), '--exit', String(status)], {
      stdio: ['ignore', 'ignore', 'ignore'],
      env: process.env,
    })
  } catch { /* ignore */ }
}

async function resolveCwd(ctx, configured) {
  if (typeof configured === 'string' && configured.trim() !== '') return configured
  const fs = ctx.get('fs')
  if (fs === undefined) return process.cwd()
  return fs.processPath(await fs.resolve('.'))
}

async function resolveTask(config) {
  if (config.task !== undefined && config.task !== '-' && String(config.task).trim() !== '') {
    return String(config.task)
  }
  if (config.task === '-' || config.task === undefined) {
    const chunks = []
    for await (const chunk of process.stdin) chunks.push(chunk)
    const text = Buffer.concat(chunks).toString('utf8')
    if (text.trim() === '') throw new Error('factory-orchestrator: a task is required')
    return text
  }
  throw new Error('factory-orchestrator: a task is required')
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {z.infer<typeof Config>} config
 * @param {{ stdout: NodeJS.WritableStream, stderr: NodeJS.WritableStream, exit: (code: number) => void }} io
 */
async function run(ctx, config, io) {
  const task = await resolveTask(config)
  const cwd = await resolveCwd(ctx, config.cwd)
  const provider = config.provider || 'claude-code'
  const timeoutMs = resolveTimeoutMs(config.timeoutMs, process.env)
  const label = config.label || 'factory-step'
  const json = config.json === true

  // Prefer injected services (Cordis inject); fall back to get for resilience.
  const agentRegistry = ctx.agents ?? ctx.get('agents')
  const subagents = ctx.subagents ?? ctx.get('subagents')
  if (agentRegistry === undefined) throw new Error('factory-orchestrator: ctx.agents is required')
  if (subagents === undefined) throw new Error('factory-orchestrator: ctx.subagents is required')

  const sessionId = brandString(`factory-${randomUUID()}`)
  const agentOptions = {
    provider: config.dummyProvider || 'deepseek-official',
    model: config.dummyModel || 'deepseek-flash',
  }

  io.stderr.write(`factory: step start provider=${provider} cwd=${cwd} timeoutMs=${timeoutMs}\n`)
  agmsgProgress('start', `provider=${provider} cwd=${cwd}`)

  const handle = await agentRegistry.create({
    sessionId,
    meta: { cwd },
    agentOptions,
  })
  const agent = handle.agent

  const controller = new AbortController()
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    io.stderr.write(`factory: timeout after ${timeoutMs}ms — aborting child\n`)
    controller.abort(new Error(`factory-orchestrator: step timed out after ${timeoutMs}ms`))
  }, timeoutMs)
  if (typeof timer.unref === 'function') timer.unref()

  let activation
  try {
    activation = await subagents.startActivation({
      provider,
      label,
      delivery: 'caller',
      signal: controller.signal,
      request: {
        cwd,
        prompt: [{ type: 'text', text: task }],
        parent: agent,
      },
    })
  } catch (error) {
    clearTimeout(timer)
    agmsgProgress('end', `startActivation failed: ${error?.message || error}`)
    io.stderr.write(`factory: startActivation failed: ${error?.message || error}\n`)
    if (json) {
      io.stdout.write(`${JSON.stringify({
        stopReason: 'error',
        output: [],
        diagnostic: String(error?.message || error),
      })}\n`)
    }
    try { await handle.dispose() } catch { /* ignore */ }
    io.exit(1)
    return
  }

  let result
  try {
    result = await activation.result
  } catch (error) {
    clearTimeout(timer)
    agmsgProgress('end', `activation rejected: ${error?.message || error}`)
    io.stderr.write(`factory: activation rejected: ${error?.message || error}\n`)
    try { await activation.dispose() } catch { /* ignore */ }
    try { await handle.dispose() } catch { /* ignore */ }
    if (timedOut) {
      io.stderr.write('factory: step end stopReason=timeout exit=124\n')
      if (json) {
        io.stdout.write(`${JSON.stringify({
          stopReason: 'timeout',
          output: [],
          diagnostic: String(error?.message || error),
        })}\n`)
      }
      io.exit(124)
      return
    }
    if (json) {
      io.stdout.write(`${JSON.stringify({
        stopReason: 'error',
        output: [],
        diagnostic: String(error?.message || error),
      })}\n`)
    }
    io.exit(1)
    return
  } finally {
    clearTimeout(timer)
  }

  try {
    await activation.dispose()
  } catch (error) {
    io.stderr.write(`factory: dispose warning: ${error?.message || error}\n`)
  }
  try {
    await handle.dispose()
  } catch (error) {
    io.stderr.write(`factory: parent dispose warning: ${error?.message || error}\n`)
  }

  const raw = result?.stopReason ?? 'error'
  const code = exitCodeFor(raw, timedOut)
  const stopReason = code === 124 ? 'timeout' : raw
  const text = textFromOutput(result?.output)
  io.stderr.write(`factory: step end stopReason=${stopReason} exit=${code}\n`)
  agmsgProgress('end', `stopReason=${stopReason} exit=${code}`)

  if (json) {
    const payload = {
      stopReason,
      output: result?.output ?? [],
      text,
    }
    if (result?.diagnostic) payload.diagnostic = result.diagnostic
    // Usage passthrough (tokens) if DSH ever exposes it; factory-usage parses `usage`.
    if (result?.usage) payload.usage = result.usage
    io.stdout.write(`${JSON.stringify(payload)}\n`)
  } else if (text !== '') {
    io.stdout.write(text.endsWith('\n') ? text : `${text}\n`)
  }

  io.exit(code)
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {z.infer<typeof Config>} config
 */
export function apply(ctx, config) {
  const exit = ctx.get('appExit')
  if (exit === undefined) {
    throw new Error('factory-orchestrator: the launcher must provide ctx.appExit before the tree mounts')
  }
  const io = {
    stdout: process.stdout,
    stderr: process.stderr,
    exit,
  }
  run(ctx, config, io).catch((error) => {
    io.stderr.write(`factory: ${error?.message || error}\n`)
    io.exit(1)
  })
}
