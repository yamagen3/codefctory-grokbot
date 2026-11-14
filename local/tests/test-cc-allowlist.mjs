import assert from 'node:assert/strict'
import { isWriteAllowed, makeCanUseTool, extractFilePaths } from '../../lib/cc/allowlist.js'

const cwd = '/tmp/factory-prod'

assert.equal(isWriteAllowed('spec', cwd, 'spec/PRODUCT.md'), true)
assert.equal(isWriteAllowed('spec', cwd, 'tests/acceptance/test_cli.py'), true)
assert.equal(isWriteAllowed('spec', cwd, 'src/csv2md/cli.py'), false)
assert.equal(isWriteAllowed('spec', cwd, '/etc/passwd'), false)
assert.equal(isWriteAllowed('gate', cwd, 'spec/PRODUCT.md'), false)
assert.equal(isWriteAllowed('unrestricted', cwd, 'src/x.py'), true)

const canSpec = makeCanUseTool('spec', cwd)
assert.equal((await canSpec('AskUserQuestion', {})).behavior, 'deny')
assert.equal((await canSpec('Write', { file_path: `${cwd}/spec/PRODUCT.md` })).behavior, 'allow')
assert.equal((await canSpec('Write', { file_path: `${cwd}/src/x.py` })).behavior, 'deny')
assert.equal((await canSpec('WebFetch', { url: 'http://x' })).behavior, 'deny')
assert.equal((await canSpec('Bash', { command: 'curl https://evil' })).behavior, 'deny')
assert.equal((await canSpec('Bash', { command: 'python -m unittest' })).behavior, 'allow')

const canGate = makeCanUseTool('gate', cwd)
assert.equal((await canGate('Write', { file_path: `${cwd}/spec/PRODUCT.md` })).behavior, 'deny')
assert.equal((await canGate('Read', { file_path: `${cwd}/spec/PRODUCT.md` })).behavior, 'allow')

assert.deepEqual(extractFilePaths('Write', { file_path: 'a.py' }), ['a.py'])
console.log('test-cc-allowlist: PASS')
