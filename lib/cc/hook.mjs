#!/usr/bin/env node
/**
 * Claude Code command hook for factory steps (wired by bin/factory-step via --settings).
 *
 *   node lib/cc/hook.mjs pretooluse    PreToolUse: factory path allowlist (allowlist.js)
 *   node lib/cc/hook.mjs stop          Stop: record the effort level that ran
 *   node lib/cc/hook.mjs stop-failure  StopFailure: record the API error category
 *
 * Input is the hook JSON on stdin (https://code.claude.com/docs/en/hooks).
 * PreToolUse replies with hookSpecificOutput.permissionDecision allow|deny and
 * exits 0. Any failure denies the tool call. Stop hooks never block.
 * Records go to $FACTORY_CC_USAGE_FILE (one JSON object per line).
 */
import fs from 'node:fs'
import { makeCanUseTool } from './allowlist.js'

async function readStdin() {
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(chunk)
  const text = Buffer.concat(chunks).toString('utf8')
  try {
    return JSON.parse(text)
  } catch {
    return {}
  }
}

function record(entry) {
  const file = process.env.FACTORY_CC_USAGE_FILE
  if (!file) return
  try {
    fs.appendFileSync(file, JSON.stringify(entry) + '\n')
  } catch { /* usage is advisory */ }
}

function decision(behavior, reason) {
  return {
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: behavior === 'allow' ? 'allow' : 'deny',
      permissionDecisionReason: reason || (behavior === 'allow' ? 'factory allowlist' : 'factory allowlist: denied'),
    },
  }
}

export async function preToolUse(input, env = process.env) {
  const step = env.FACTORY_CC_STEP || ''
  const toolName = String(input?.tool_name || '')
  if (!step) {
    return decision('deny', 'This unattended factory Claude Code step cannot request human approval.')
  }
  if (!toolName) {
    return decision('deny', 'factory allowlist: hook input without tool_name')
  }
  const cwd = env.FACTORY_CC_CWD || input?.cwd || process.cwd()
  try {
    const decide = makeCanUseTool(step, cwd)
    const result = await decide(toolName, input?.tool_input || {})
    return decision(result.behavior, result.message)
  } catch (error) {
    return decision('deny', `factory allowlist handler failed: ${error?.message || error}`)
  }
}

async function main() {
  const mode = process.argv[2] || ''
  const input = await readStdin()
  if (mode === 'pretooluse') {
    const out = await preToolUse(input)
    process.stdout.write(JSON.stringify(out) + '\n')
    return
  }
  if (mode === 'stop') {
    record({ source: 'claude-cli.stop-hook', effort: input?.effort?.level ?? process.env.CLAUDE_EFFORT ?? null })
    return
  }
  if (mode === 'stop-failure') {
    const head = typeof input?.last_assistant_message === 'string' ? input.last_assistant_message.slice(0, 300) : null
    record({
      source: 'claude-cli.stop-failure',
      error: input?.error ?? null,
      error_details: typeof input?.error_details === 'string' ? input.error_details.slice(0, 300) : null,
      result_head: head,
    })
    return
  }
  process.stderr.write('usage: hook.mjs pretooluse|stop|stop-failure\n')
  process.exitCode = 2
}

const invoked = process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())
if (invoked) {
  main().catch((error) => {
    // A PreToolUse failure must deny, never allow.
    if ((process.argv[2] || '') === 'pretooluse') {
      process.stdout.write(JSON.stringify(decision('deny', `factory hook failed: ${error?.message || error}`)) + '\n')
    }
  })
}
