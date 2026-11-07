/**
 * SDK options that make factory Claude Code sessions load pstack skills.
 *
 * DSH's claude-code provider omits `settingSources` and never reads
 * ~/.agents/skills. Copying SKILL.md files into ~/.claude/skills does not put
 * their text into a spec or gate prompt. This module is spread into the
 * Agent SDK query options (see scripts/apply-cc-allowlist-patch.sh).
 *
 * Shape chosen over the upstream SessionStart plugin hook: that hook injects
 * "invoke pstack:poteto-mode", which routes into Agent-tool model fan-out.
 * Factory CC stays claude-opus-5-5 at xhigh and does not own implementation.
 */
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
export const FACTORY_ROOT = path.resolve(here, '../..')

/** Stage → skill directory names. Each name is a manifest subset, not the library. */
export const STAGE_SKILLS = {
  spec: [
    'principle-model-the-domain',
    'principle-sequence-verifiable-units',
    'principle-prove-it-works',
    'technical-writing',
  ],
  gate: [
    'principle-prove-it-works',
    'principle-test-behavior-not-implementation',
    'show-me-your-work',
  ],
}

/** Fail closed rather than inlining a playbook that spawns subagents. */
const MAX_SKILL_CHARS = 16000

export function stageSkillNames() {
  return [...new Set(Object.values(STAGE_SKILLS).flat())]
}

function manifestNames(factoryRoot) {
  const file = path.join(factoryRoot, 'config/pstack-skills.manifest')
  const text = fs.readFileSync(file, 'utf8')
  return new Set(
    text
      .split('\n')
      .map((line) => line.trim())
      .filter((line) => line && !line.startsWith('#')),
  )
}

function frontmatterName(raw, file) {
  if (!raw.startsWith('---\n')) return null
  const end = raw.indexOf('\n---', 4)
  if (end === -1) return null
  for (const line of raw.slice(4, end).split('\n')) {
    if (line.startsWith('name:')) return line.slice(5).trim().replace(/^["']|["']$/g, '')
  }
  throw new Error(`pstack skill ${file} has frontmatter without name`)
}

function loadSkill(skillsRoot, dirName) {
  const file = path.join(skillsRoot, dirName, 'SKILL.md')
  if (!fs.existsSync(file)) {
    throw new Error(`pstack skill missing: ${file} (run factory-pstack-install / factory-setup)`)
  }
  const raw = fs.readFileSync(file, 'utf8')
  if (raw.length > MAX_SKILL_CHARS) {
    throw new Error(`pstack skill ${dirName} is ${raw.length} chars; stage bootstrap cap is ${MAX_SKILL_CHARS}`)
  }
  const name = frontmatterName(raw, file) ?? dirName
  if (name !== dirName) {
    throw new Error(`pstack skill directory ${dirName} frontmatter name is ${name}`)
  }
  return { name, file, raw }
}

function renderAppend(step, skillsRoot, loaded) {
  const lines = [
    `Factory pstack bootstrap for CC step=${step}.`,
    'These are the stage skill instructions, not a pointer at files that may go unread.',
    `Skill files: ${skillsRoot}. Session cwd is the product repo and is not the skill root.`,
    'This session stays on the factory-pinned Claude model and effort. Do not change models.',
    'Do not call Agent, AskUserQuestion, or setup-pstack. Do not start arena, swarm, reflect, or interrogate.',
    'OpenCode implements. This step does not. IMPL parallelism is only spec/IMPL_STRATEGY.md (parallel: N, 1..4), not a multi-model fan-out.',
    'If a skill tells you to use Cursor Task, subagent model routing, pstack-models.md, or the SessionStart poteto-mode route, skip that step and write skip: <reason>.',
    '',
  ]
  for (const skill of loaded) {
    lines.push(`## pstack skill: ${skill.name}`, `path: ${skill.file}`, '', skill.raw.trimEnd(), '')
  }
  return lines.join('\n')
}

/**
 * Options spread into Agent SDK query(). Synchronous: claudeQueryOptions is sync.
 * @param {{ step?: string, skillsRoot?: string, factoryRoot?: string, home?: string }} [options]
 */
export function pstackQueryOverlay(options = {}) {
  const step = options.step ?? process.env.FACTORY_CC_STEP ?? ''
  const home = options.home ?? process.env.HOME ?? ''
  const skillsRoot = options.skillsRoot
    ?? process.env.FACTORY_PSTACK_SKILLS_DIR
    ?? path.join(home, '.claude', 'skills')
  const factoryRoot = options.factoryRoot ?? process.env.FACTORY_ROOT ?? FACTORY_ROOT
  const overlay = { settingSources: ['user'] }
  const names = STAGE_SKILLS[step]
  let loaded = []
  let append = ''
  if (names) {
    const allowed = manifestNames(factoryRoot)
    for (const name of names) {
      if (!allowed.has(name)) throw new Error(`pstack stage ${step} names ${name}, which is not in the manifest`)
    }
    loaded = names.map((name) => loadSkill(skillsRoot, name))
    append = renderAppend(step, skillsRoot, loaded)
    overlay.skills = names.slice()
    overlay.systemPrompt = { type: 'preset', preset: 'claude_code', append }
  }
  const log = process.env.FACTORY_PSTACK_OVERLAY_LOG
  if (log) {
    const record = {
      step: step || null,
      skillsRoot,
      settingSources: overlay.settingSources,
      skills: overlay.skills ?? null,
      paths: loaded.map((skill) => skill.file),
      appendChars: append.length,
      appendSha256: append ? crypto.createHash('sha256').update(append).digest('hex') : null,
    }
    fs.appendFileSync(log, JSON.stringify(record) + '\n')
  }
  return overlay
}
