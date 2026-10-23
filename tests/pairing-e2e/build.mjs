// Compiles TodeX_protocol's sources to CommonJS under dist/protocol. The
// sources are copied here first so their `@noble/*` imports resolve to this
// package's node_modules, whether or not the protocol checkout has its own.
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const protocol = resolve(process.env.TODEX_PROTOCOL_DIR ?? join(here, '../../../TodeX_protocol'));
const source = join(here, 'dist/src');
const output = join(here, 'dist/protocol');

rmSync(join(here, 'dist'), { recursive: true, force: true });
mkdirSync(source, { recursive: true });
cpSync(join(protocol, 'src'), source, { recursive: true });
const files = readdirSync(source).filter((name) => name.endsWith('.ts')).map((name) => join(source, name));
execFileSync(join(here, 'node_modules/.bin/tsc'), [
  '--ignoreConfig', ...files, '--outDir', output,
  '--module', 'commonjs', '--target', 'es2022', '--moduleResolution', 'node', '--ignoreDeprecations', '6.0',
  '--esModuleInterop', '--skipLibCheck', '--strict',
], { stdio: 'inherit' });
writeFileSync(join(output, 'package.json'), '{ "type": "commonjs" }\n');
