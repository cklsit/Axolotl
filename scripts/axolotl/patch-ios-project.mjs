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

import { cp, mkdir, readFile, writeFile } from 'node:fs/promises'
import { spawnSync } from 'node:child_process'
import { join, resolve } from 'node:path'

const projectRoot = resolve('.')
const appleDir = join(projectRoot, 'apps/app/gen/apple')
const projectFile = join(appleDir, 'project.yml')
const bridgeSource = join(projectRoot, 'apps/app/ios')
const bridgeTarget = join(appleDir, 'Sources/launcher')
// Only the loader is compiled into the application. The game runtime, which
// serves the symbols the game resolves by name, is built as its own library so
// the game and the launcher share one copy of it.
const bridgeFiles = ['AxolotlLoader.m', 'AxolotlRuntime.h']

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
    // The launcher publishes a copy of its log in the documents directory, which
    // the file browser can only reach when the application shares documents.
    [
        '        LSRequiresIPhoneOS: true',
        [
            '        LSRequiresIPhoneOS: true',
            '        UIFileSharingEnabled: true',
            '        LSSupportsOpeningDocumentsInPlace: true',
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
for (const entry of bridgeFiles) {
    await cp(join(bridgeSource, entry), join(bridgeTarget, entry))
}

// The runtime folder is filled with the bundled Java runtime after this script
// runs, so only the reference needs to exist for the project to generate.
await mkdir(join(appleDir, 'GameRuntime'), { recursive: true })

// The project file was generated before the bridge sources and the runtime
// folder existed, so it has to be regenerated from the patched description.
const generated = spawnSync('xcodegen', ['generate'], {
    cwd: appleDir,
    stdio: 'inherit',
})
if (generated.error) {
    throw generated.error
}
if (generated.status !== 0) {
    throw new Error(`xcodegen generate exited with ${generated.status}`)
}

console.log(`Patched ${projectFile}`)
console.log(`Staged the native bridge in ${bridgeTarget}`)
