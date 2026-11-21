// Rewrites the iOS Xcode project that `tauri ios init` generates so it matches
// this workspace.
//
// The generated project links a static library whose name comes from the Cargo
// package, and it drives the Rust build through `pnpm`. Renaming the library to
// the crate name keeps the desktop binary and the mobile host on the same crate
// path, and calling the CLI entry script directly keeps the Xcode build phase
// from starting a package manager install inside Xcode, which has no terminal
// to answer its prompts.

import { readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'

const projectFile = resolve('apps/app/gen/apple/project.yml')
const libraryReplacements = [
    ['libapp.a', 'libtheseus_gui.a'],
    [
        'script: pnpm tauri ios xcode-script',
        'script: node ../../node_modules/@tauri-apps/cli/tauri.js ios xcode-script',
    ],
]

const original = await readFile(projectFile, 'utf8')
let patched = original
for (const [from, to] of libraryReplacements) {
    if (!original.includes(from)) {
        throw new Error(`iOS project template no longer contains: ${from}`)
    }
    patched = patched.split(from).join(to)
}

if (patched === original) {
    throw new Error('iOS project template needed no change but reported a match')
}

await writeFile(projectFile, patched)
console.log(`Patched ${projectFile}`)
