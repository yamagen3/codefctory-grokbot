/**
 * pstack stage skills for factory Claude Code steps.
 *
 * The factory runs the standard `claude -p` CLI. This module renders the text
 * that bin/factory-step passes with --append-system-prompt-file, so the SPEC
 * and GATE steps carry their stage skill instructions in the system prompt.
 * The session reads user settings (--setting-sources user) so ~/.claude/skills
 * is the skill root.
 *
 * CLI: node lib/cc/pstack-session.js render <step> <out-file>
 *   Writes the append text for <step> (spec|gate) to <out-file>. Prints the
 *   number of characters written. A step with no stage skills writes nothing
 *   and prints 0. A missing or oversized skill exits 1 (fail closed).
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
 * Stage bootstrap for one CC step.
 * @param {{ step?: string, skillsRoot?: string, factoryRoot?: string, home?: string }} [options]
 * @returns {{ step: string|null, settingSources: string[], skills: string[]|null, paths: string[], append: string }}
 */
export function stageBootstrap(options = {}) {
  const step = options.step ?? process.env.FACTORY_CC_STEP ?? ''
  const home = options.home ?? process.env.HOME ?? ''
  const skillsRoot = options.skillsRoot
    ?? process.env.FACTORY_PSTACK_SKILLS_DIR
    ?? path.join(home, '.claude', 'skills')
  const factoryRoot = options.factoryRoot ?? process.env.FACTORY_ROOT ?? FACTORY_ROOT
  const names = Object.prototype.hasOwnProperty.call(STAGE_SKILLS, step) ? STAGE_SKILLS[step] : null
  let loaded = []
  let append = ''
  if (names) {
    const allowed = manifestNames(factoryRoot)
    for (const name of names) {
      if (!allowed.has(name)) throw new Error(`pstack stage ${step} names ${name}, which is not in the manifest`)
    }
    loaded = names.map((name) => loadSkill(skillsRoot, name))
    append = renderAppend(step, skillsRoot, loaded)
  }
  const result = {
    step: step || null,
    settingSources: ['user'],
    skills: names ? names.slice() : null,
    paths: loaded.map((skill) => skill.file),
    append,
  }
  const log = process.env.FACTORY_PSTACK_OVERLAY_LOG
  if (log) {
    const record = {
      step: result.step,
      skillsRoot,
      settingSources: result.settingSources,
      skills: result.skills,
      paths: result.paths,
      appendChars: append.length,
      appendSha256: append ? crypto.createHash('sha256').update(append).digest('hex') : null,
    }
    fs.appendFileSync(log, JSON.stringify(record) + '\n')
  }
  return result
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [cmd, step, out] = process.argv.slice(2)
  if (cmd === 'render' && out) {
    try {
      const { append } = stageBootstrap({ step: step ?? '' })
      fs.writeFileSync(out, append)
      process.stdout.write(`${append.length}\n`)
    } catch (error) {
      process.stderr.write(`pstack-session: ${error?.message || error}\n`)
      process.exit(1)
    }
  } else if (cmd === 'skills') {
    for (const name of stageSkillNames()) process.stdout.write(`${name}\n`)
  } else {
    process.stderr.write('usage: pstack-session.js render <step> <out-file> | skills\n')
    process.exit(2)
  }
}
