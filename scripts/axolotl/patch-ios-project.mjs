// Rewrites the iOS Xcode project that `tauri ios init` generates so it matches
// this workspace, and stages the native bridge into it.
//
// The generated project links a static library whose name comes from the Cargo
// package, and it drives the Rust build through `pnpm`. Renaming the library to
// the crate name keeps the desktop binary and the mobile host on the same crate
// path, and calling the CLI entry script directly keeps the Xcode build phase
// from starting a package manager install inside Xcode, which has no terminal to
// answer its prompts.
//
// The bridge sources and the bundled game runtime live outside the generated
// directory; both are copied in here so the Xcode project stays a build output.

import { cp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'

const projectRoot = resolve('.')
const appleDir = join(projectRoot, 'apps/app/gen/apple')
const projectFile = join(appleDir, 'project.yml')
const bridgeSource = join(projectRoot, 'apps/app/ios')
const bridgeTarget = join(appleDir, 'Sources/launcher')

const projectReplacements = [
    ['libapp.a', 'libtheseus_gui.a'],
    [
        'script: pnpm tauri ios xcode-script',
        'script: node ../../node_modules/@tauri-apps/cli/tauri.js ios xcode-script',
    ],
    [
        '      - path: LaunchScreen.storyboard',
        [
            '      - path: GameRuntime',
            '        buildPhase: resources',
            '        type: folder',
            '      - path: LaunchScreen.storyboard',
        ].join('\n'),
    ],
]

const original = await readFile(projectFile, 'utf8')
let patched = original
for (const [from, to] of projectReplacements) {
    if (!original.includes(from)) {
        throw new Error(`iOS project template no longer contains: ${from}`)
    }
    patched = patched.split(from).join(to)
}
await writeFile(projectFile, patched)

await mkdir(bridgeTarget, { recursive: true })
for (const entry of await readdir(bridgeSource)) {
    await cp(join(bridgeSource, entry), join(bridgeTarget, entry))
}

console.log(`Patched ${projectFile}`)
console.log(`Staged the native bridge in ${bridgeTarget}`)
