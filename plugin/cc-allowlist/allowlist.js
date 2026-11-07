/**
 * Path allowlists for factory Claude Code steps.
 * FACTORY_CC_STEP=spec|gate|impl-cc|unrestricted
 */
import path from 'node:path'
import fs from 'node:fs'

export const STEPS = {
  spec: {
    writePrefixes: ['spec/', 'tests/acceptance/'],
    allowRead: true,
    allowNetwork: false,
    denyTools: ['AskUserQuestion', 'ExitPlanMode'],
  },
  gate: {
    writePrefixes: [],
    allowRead: true,
    allowNetwork: false,
    denyTools: ['AskUserQuestion', 'ExitPlanMode', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit'],
  },
  'impl-cc': {
    writePrefixes: ['src/', 'tests/unit/'],
    allowRead: true,
    allowNetwork: false,
    denyTools: ['AskUserQuestion'],
  },
  unrestricted: {
    writePrefixes: null,
    allowRead: true,
    allowNetwork: true,
    denyTools: ['AskUserQuestion'],
  },
}

export function normalizeRel(cwd, filePath) {
  if (!filePath || typeof filePath !== 'string') return null
  const abs = path.isAbsolute(filePath) ? filePath : path.resolve(cwd, filePath)
  const rel = path.relative(cwd, abs).replace(/\\/g, '/')
  if (rel.startsWith('..') || path.isAbsolute(rel)) return null
  return rel
}

export function isWriteAllowed(stepName, cwd, filePath) {
  const step = STEPS[stepName] || STEPS.spec
  if (step.writePrefixes === null) return true
  if (!step.writePrefixes.length) return false
  const rel = normalizeRel(cwd, filePath)
  if (rel === null) return false
  return step.writePrefixes.some((p) => rel === p.replace(/\/$/, '') || rel.startsWith(p))
}

export function extractFilePaths(toolName, input) {
  if (!input || typeof input !== 'object') return []
  const paths = []
  for (const key of ['file_path', 'filePath', 'path', 'notebook_path']) {
    if (typeof input[key] === 'string') paths.push(input[key])
  }
  if (Array.isArray(input.edits)) {
    for (const e of input.edits) {
      if (e && typeof e.file_path === 'string') paths.push(e.file_path)
      if (e && typeof e.filePath === 'string') paths.push(e.filePath)
    }
  }
  return paths
}

const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit'])

export function makeCanUseTool(stepName, cwd) {
  const step = STEPS[stepName] || STEPS.spec
  return async (toolName, input) => {
    let result
    if (step.denyTools.includes(toolName) || toolName === 'AskUserQuestion') {
      result = { behavior: 'deny', message: `factory allowlist: tool ${toolName} denied for step=${stepName}` }
    } else if (!step.allowNetwork && /^(WebFetch|WebSearch|Bash)$/.test(toolName)) {
      if (toolName === 'Bash') {
        const cmd = String(input?.command || '')
        if (/\b(curl|wget|nc|netcat|ssh|scp|fetch|pip install|npm (install|publish))\b/i.test(cmd)) {
          result = { behavior: 'deny', message: `factory allowlist: network-ish bash denied for step=${stepName}` }
        } else if (stepName === 'gate' && /\b(rm|mv|cp|tee|sed -i|chmod|mkdir|touch|git\s+commit|git\s+add)\b/i.test(cmd)) {
          result = { behavior: 'deny', message: 'factory allowlist: mutating bash denied for gate' }
        } else {
          result = { behavior: 'allow' }
        }
      } else {
        result = { behavior: 'deny', message: `factory allowlist: ${toolName} denied (no network)` }
      }
    } else if (WRITE_TOOLS.has(toolName)) {
      const files = extractFilePaths(toolName, input)
      if (!files.length) {
        result = { behavior: 'deny', message: 'factory allowlist: write tool without path' }
      } else {
        let denied = null
        for (const f of files) {
          if (!isWriteAllowed(stepName, cwd, f)) {
            denied = { behavior: 'deny', message: `factory allowlist: write denied for ${f} (step=${stepName})` }
            break
          }
        }
        result = denied || { behavior: 'allow' }
      }
    } else {
      result = { behavior: 'allow' }
    }
    try {
      fs.appendFileSync(
        '/tmp/cc-allowlist-decisions.log',
        JSON.stringify({ step: stepName, cwd, toolName, input, result }) + '\n',
      )
    } catch { /* ignore */ }
    return result
  }
}
