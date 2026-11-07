/**
 * Offline: the object spread into the Agent SDK query for a CC child.
 * Does not spawn Claude, DSH, or the network, and uses no credentials.
 */
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { STAGE_SKILLS, pstackQueryOverlay, stageSkillNames } from '../../plugin/cc-allowlist/pstack-session.js'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const manifest = fs.readFileSync(path.join(root, 'config/pstack-skills.manifest'), 'utf8')
const manifestNames = new Set(
  manifest.split('\n').map((line) => line.trim()).filter((line) => line && !line.startsWith('#')),
)
const excluded = ['poteto-mode', 'arena', 'swarm', 'reflect', 'setup-pstack', 'interrogate', 'thermos', 'tdd', 'architect']
for (const name of stageSkillNames()) {
  assert.equal(manifestNames.has(name), true, `${name} left the manifest`)
}
for (const name of excluded) {
  for (const [step, list] of Object.entries(STAGE_SKILLS)) {
    assert.equal(list.includes(name), false, `${step} must not bootstrap ${name}`)
  }
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pstack-cc-'))
const skills = path.join(dir, 'skills')
fs.mkdirSync(skills, { recursive: true })
const marker = {}
for (const name of stageSkillNames()) {
  marker[name] = `FIXTURE_BODY_${name}_END`
  fs.mkdirSync(path.join(skills, name))
  fs.writeFileSync(path.join(skills, name, 'SKILL.md'), `---\nname: ${name}\n---\n\n# ${name}\n\n${marker[name]}\n`)
}
fs.mkdirSync(path.join(skills, 'poteto-mode'))
fs.writeFileSync(path.join(skills, 'poteto-mode', 'SKILL.md'), '---\nname: poteto-mode\n---\n\nPOTETO_MODE_SHOULD_NOT_LEAK\n')

const log = path.join(dir, 'overlay.jsonl')
const base = { skillsRoot: skills, factoryRoot: root, home: path.join(dir, 'home') }
process.env.FACTORY_PSTACK_OVERLAY_LOG = log

function run(step) {
  return pstackQueryOverlay({ ...base, step })
}

const spec = run('spec')
const specAgain = run('spec')
assert.deepEqual(spec, specAgain)
assert.deepEqual(spec.settingSources, ['user'])
assert.deepEqual(spec.skills, STAGE_SKILLS.spec)
assert.deepEqual(spec.systemPrompt.type, 'preset')
assert.equal(spec.systemPrompt.preset, 'claude_code')
assert.equal(Object.hasOwn(spec, 'permissionMode'), false)
assert.equal(Object.hasOwn(spec, 'model'), false)
assert.equal(JSON.stringify(spec).includes('bypassPermissions'), false)
assert.equal(spec.systemPrompt.append.includes('Do not change models.'), true)
assert.equal(spec.systemPrompt.append.includes('not a multi-model fan-out'), true)
for (const name of STAGE_SKILLS.spec) {
  assert.equal(spec.systemPrompt.append.includes(marker[name]), true, `spec missing ${name}`)
  assert.equal(spec.systemPrompt.append.includes(path.join(skills, name, 'SKILL.md')), true)
}
assert.equal(spec.systemPrompt.append.includes('POTETO_MODE_SHOULD_NOT_LEAK'), false)
assert.equal(spec.systemPrompt.append.includes(marker['show-me-your-work']), false)

const gate = run('gate')
assert.deepEqual(gate.skills, STAGE_SKILLS.gate)
for (const name of STAGE_SKILLS.gate) assert.equal(gate.systemPrompt.append.includes(marker[name]), true)
assert.equal(gate.systemPrompt.append.includes(marker['technical-writing']), false)
assert.equal(gate.systemPrompt.append.includes('step=gate'), true)

const other = run('')
assert.deepEqual(other, { settingSources: ['user'] })
assert.equal(other.systemPrompt, undefined)

assert.throws(() => pstackQueryOverlay({ ...base, skillsRoot: path.join(dir, 'missing'), step: 'spec' }), /pstack skill missing/)

const huge = path.join(dir, 'huge')
fs.mkdirSync(path.join(huge, 'principle-prove-it-works'), { recursive: true })
fs.writeFileSync(
  path.join(huge, 'principle-prove-it-works', 'SKILL.md'),
  `---\nname: principle-prove-it-works\n---\n\n${'x'.repeat(17000)}\n`,
)
assert.throws(() => pstackQueryOverlay({ ...base, skillsRoot: huge, step: 'gate' }), /stage bootstrap cap/)

const lines = fs.readFileSync(log, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
const specLog = lines.filter((row) => row.step === 'spec')
assert.equal(specLog.length >= 1, true)
assert.deepEqual(specLog[0].settingSources, ['user'])
assert.deepEqual(specLog[0].skills, STAGE_SKILLS.spec)
assert.equal(specLog[0].paths.length, STAGE_SKILLS.spec.length)
assert.equal(specLog[0].appendSha256, crypto.createHash('sha256').update(spec.systemPrompt.append).digest('hex'))
assert.equal(JSON.stringify(specLog).includes('FIXTURE_BODY'), false)

console.log(JSON.stringify({
  spec: { settingSources: spec.settingSources, skills: spec.skills, appendChars: spec.systemPrompt.append.length },
  gate: { settingSources: gate.settingSources, skills: gate.skills, appendChars: gate.systemPrompt.append.length },
  other: other,
}, null, 2))
console.log('test_pstack_cc_session: PASS')
