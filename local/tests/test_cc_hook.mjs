/**
 * Offline: the Claude Code PreToolUse/Stop hook (lib/cc/hook.mjs) that replaced the
 * Agent SDK canUseTool patch. Spawns only node; no Claude, network, or credentials.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const hook = path.join(root, 'lib/cc/hook.mjs')
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cc-hook-'))
const cwd = path.join(dir, 'repo')
fs.mkdirSync(cwd)

function call(mode, input, env = {}) {
  const r = spawnSync('node', [hook, mode], {
    input: JSON.stringify(input),
    env: { ...process.env, FACTORY_CC_CWD: cwd, ...env },
    encoding: 'utf8',
  })
  assert.equal(r.status, 0, `hook ${mode} exited ${r.status}: ${r.stderr}`)
  return r.stdout.trim() ? JSON.parse(r.stdout) : null
}

function decision(step, tool, toolInput) {
  const out = call('pretooluse', { hook_event_name: 'PreToolUse', cwd, tool_name: tool, tool_input: toolInput },
    step === null ? { FACTORY_CC_STEP: '' } : { FACTORY_CC_STEP: step })
  assert.equal(out.hookSpecificOutput.hookEventName, 'PreToolUse')
  return out.hookSpecificOutput.permissionDecision
}

// No step: an unattended run cannot ask a human, so every tool is denied.
assert.equal(decision(null, 'Read', { file_path: `${cwd}/x` }), 'deny')
// SPEC writes only spec/ and tests/acceptance/.
assert.equal(decision('spec', 'Write', { file_path: `${cwd}/spec/PRODUCT.md` }), 'allow')
assert.equal(decision('spec', 'Write', { file_path: `${cwd}/tests/acceptance/test_a.py` }), 'allow')
assert.equal(decision('spec', 'Write', { file_path: `${cwd}/src/app.py` }), 'deny')
assert.equal(decision('spec', 'Edit', { file_path: '/etc/passwd' }), 'deny')
assert.equal(decision('spec', 'Bash', { command: 'curl https://example.com' }), 'deny')
assert.equal(decision('spec', 'Bash', { command: 'python3 -m unittest' }), 'allow')
assert.equal(decision('spec', 'WebFetch', { url: 'https://example.com' }), 'deny')
assert.equal(decision('spec', 'AskUserQuestion', {}), 'deny')
// GATE is read-only.
assert.equal(decision('gate', 'Write', { file_path: `${cwd}/spec/PRODUCT.md` }), 'deny')
assert.equal(decision('gate', 'Bash', { command: 'rm -rf src' }), 'deny')
assert.equal(decision('gate', 'Read', { file_path: `${cwd}/spec/PRODUCT.md` }), 'allow')
// Unknown step denies.
assert.equal(decision('nope', 'Read', { file_path: `${cwd}/x` }), 'deny')
// Garbage input denies rather than allowing.
{
  const r = spawnSync('node', [hook, 'pretooluse'], { input: 'not json', env: { ...process.env, FACTORY_CC_STEP: 'spec' }, encoding: 'utf8' })
  assert.equal(r.status, 0)
  assert.equal(JSON.parse(r.stdout).hookSpecificOutput.permissionDecision, 'deny')
}

// Stop and StopFailure records land in FACTORY_CC_USAGE_FILE and never block.
const usage = path.join(dir, 'usage.jsonl')
assert.equal(call('stop', { hook_event_name: 'Stop', effort: { level: 'xhigh' } }, { FACTORY_CC_USAGE_FILE: usage }), null)
assert.equal(call('stop-failure', { hook_event_name: 'StopFailure', error: 'rate_limit', last_assistant_message: 'API Error: Rate limit reached' },
  { FACTORY_CC_USAGE_FILE: usage }), null)
const rows = fs.readFileSync(usage, 'utf8').trim().split('\n').map((l) => JSON.parse(l))
assert.deepEqual(rows[0], { source: 'claude-cli.stop-hook', effort: 'xhigh' })
assert.equal(rows[1].source, 'claude-cli.stop-failure')
assert.equal(rows[1].error, 'rate_limit')
fs.rmSync(dir, { recursive: true, force: true })
console.log('test_cc_hook: PASS')
