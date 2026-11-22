// Pulls the latest unsigned iOS package from this repository's build and
// publishes it for the local network.
//
// A hosted macOS runner builds the package but cannot reach a home network, and
// a device installs through its own sideloading application. This script closes
// the gap: it runs on any machine on the same network as the device, keeps the
// newest package and a small install page in a directory, and the device opens
// the install link the page carries.
//
// Usage:
//   GH_TOKEN=<token> node scripts/axolotl/publish-ios-lan.mjs --out <directory> [--serve <port>] [--watch <minutes>]
//
// The token only needs to read this repository's Actions data.

import { createHash } from 'node:crypto'
import { spawn } from 'node:child_process'
import { createServer } from 'node:http'
import { createReadStream } from 'node:fs'
import { mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises'
import { basename, join, resolve } from 'node:path'

const options = parseOptions(process.argv.slice(2))
const repository = options.repo ?? 'cklsit/Axolotl'
const workflowFile = options.workflow ?? 'ios-build.yml'
const artifactName = options.artifact ?? 'axolotl-ios-unsigned'
const output = resolve(options.out ?? 'ios-lan')
const token = process.env.GH_TOKEN ?? process.env.GITHUB_TOKEN

if (!token) {
    throw new Error('Set GH_TOKEN to a token that can read this repository')
}

async function api(path, accept = 'application/vnd.github+json') {
    const response = await fetch(`https://api.github.com${path}`, {
        headers: {
            accept,
            authorization: `Bearer ${token}`,
            'x-github-api-version': '2022-11-28',
        },
    })
    if (!response.ok) {
        throw new Error(`${path} answered ${response.status}`)
    }
    return response
}

async function latestRun() {
    const response = await api(
        `/repos/${repository}/actions/workflows/${workflowFile}/runs?status=success&per_page=1`,
    )
    const body = await response.json()
    const run = body.workflow_runs?.[0]
    if (!run) {
        throw new Error('No successful build exists yet')
    }
    return run
}

async function downloadArtifact(runId, directory) {
    const response = await api(
        `/repos/${repository}/actions/runs/${runId}/artifacts`,
    )
    const body = await response.json()
    const artifact = body.artifacts?.find(
        (entry) => entry.name === artifactName && !entry.expired,
    )
    if (!artifact) {
        throw new Error(`Run ${runId} has no ${artifactName} artifact`)
    }
    const archive = await fetch(artifact.archive_download_url, {
        headers: {
            accept: 'application/vnd.github+json',
            authorization: `Bearer ${token}`,
            'x-github-api-version': '2022-11-28',
        },
        redirect: 'follow',
    })
    if (!archive.ok) {
        throw new Error(`Artifact download answered ${archive.status}`)
    }
    const path = join(directory, 'artifact.zip')
    await writeFile(path, Buffer.from(await archive.arrayBuffer()))
    return path
}

function extract(archive, directory) {
    const command = process.platform === 'win32'
        ? ['tar', ['-xf', archive, '-C', directory]]
        : ['unzip', ['-q', '-o', archive, '-d', directory]]
    return new Promise((resolveRun, rejectRun) => {
        const child = spawn(command[0], command[1], { stdio: 'inherit' })
        child.on('error', rejectRun)
        child.on('exit', (code) => {
            if (code === 0) resolveRun()
            else rejectRun(new Error(`${command[0]} finished with ${code}`))
        })
    })
}

async function findPackage(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
        const path = join(directory, entry.name)
        if (entry.isDirectory()) {
            const nested = await findPackage(path)
            if (nested) return nested
        } else if (entry.name.endsWith('.ipa')) {
            return path
        }
    }
    return null
}

async function sha256(path) {
    const digest = createHash('sha256')
    const file = createReadStream(path)
    for await (const chunk of file) {
        digest.update(chunk)
    }
    return digest.digest('hex')
}

function installPage(manifest) {
    const installUrl = `sidestore://install?url=${encodeURIComponent(manifest.ipa_url)}`
    const liveContainerUrl = `livecontainer://install?url=${encodeURIComponent(manifest.ipa_url)}`
    return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Axolotl iOS 安装</title>
<style>
body{font-family:-apple-system,system-ui,sans-serif;background:#16121c;color:#ede8f5;margin:0;padding:32px 20px;line-height:1.6}
main{max-width:520px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}
p{color:#b4aac6;margin:4px 0 20px;font-size:14px}
a.button{display:block;text-align:center;background:#c98bee;color:#1a1022;text-decoration:none;font-weight:600;padding:16px;border-radius:14px;margin:12px 0}
dl{font-size:13px;color:#9d93b0;margin-top:24px}
dt{float:left;width:96px;clear:left}
dd{margin:0 0 4px 96px;word-break:break-all}
</style>
</head>
<body>
<main>
<h1>Axolotl Launcher</h1>
<p>构建 #${manifest.run_id} · ${manifest.built_at}</p>
<a class="button" href="${installUrl}">在 SideStore 中安装</a>
<a class="button" href="${liveContainerUrl}">在 LiveContainer 中安装</a>
<dl>
<dt>文件</dt><dd>${manifest.ipa_name}</dd>
<dt>大小</dt><dd>${(manifest.size / 1048576).toFixed(1)} MB</dd>
<dt>SHA-256</dt><dd>${manifest.sha256}</dd>
</dl>
</main>
</body>
</html>
`
}

async function publish(run) {
    const staging = join(output, '.staging')
    await rm(staging, { recursive: true, force: true })
    await mkdir(staging, { recursive: true })
    const archive = await downloadArtifact(run.id, staging)
    await extract(archive, staging)
    const packagePath = await findPackage(staging)
    if (!packagePath) {
        throw new Error('The artifact carries no package')
    }
    const name = basename(packagePath)
    const destination = join(output, 'Axolotl-ios.ipa')
    await writeFile(destination, await readFile(packagePath))
    const details = await stat(destination)
    const manifest = {
        run_id: run.id,
        built_at: run.created_at,
        ipa_name: name,
        ipa_url: `${options.publicUrl ?? 'http://localhost'}/${encodeURIComponent('Axolotl-ios.ipa')}`,
        size: details.size,
        sha256: await sha256(destination),
    }
    await writeFile(join(output, 'index.json'), JSON.stringify(manifest, null, 2))
    await writeFile(join(output, 'index.html'), installPage(manifest))
    await rm(staging, { recursive: true, force: true })
    console.log(
        `Published run ${manifest.run_id} (${(manifest.size / 1048576).toFixed(1)} MB) to ${output}`,
    )
    return manifest
}

function serve(port) {
    const types = {
        '.ipa': 'application/octet-stream',
        '.json': 'application/json; charset=utf-8',
        '.html': 'text/html; charset=utf-8',
    }
    createServer(async (request, response) => {
        const requested = decodeURIComponent(
            (request.url ?? '/').split('?')[0],
        )
        const name = requested === '/' ? 'index.html' : requested.slice(1)
        if (name.includes('/') || name.includes('\\')) {
            response.writeHead(400).end()
            return
        }
        const path = join(output, name)
        try {
            const details = await stat(path)
            const extension = path.slice(path.lastIndexOf('.'))
            response.writeHead(200, {
                'content-type': types[extension] ?? 'application/octet-stream',
                'content-length': details.size,
            })
            createReadStream(path).pipe(response)
        } catch {
            response.writeHead(404).end()
        }
    }).listen(port, () => {
        console.log(`Serving ${output} on port ${port}`)
    })
}

async function once() {
    await mkdir(output, { recursive: true })
    const run = await latestRun()
    return publish(run)
}

if (options.serve) {
    if (options.watch) {
        throw new Error('Serve the directory once; run the watcher separately')
    }
    await once()
    serve(Number(options.serve))
} else if (options.watch) {
    const interval = Number(options.watch) * 60_000
    for (;;) {
        try {
            await once()
        } catch (error) {
            console.error(error.message)
        }
        await new Promise((resolveWait) => setTimeout(resolveWait, interval))
    }
} else {
    await once()
}

function parseOptions(arguments_) {
    const parsed = {}
    for (let index = 0; index < arguments_.length; index++) {
        const argument = arguments_[index]
        if (!argument.startsWith('--')) continue
        const key = argument.slice(2)
        const value = arguments_[index + 1]
        if (value === undefined || value.startsWith('--')) {
            parsed[key] = true
        } else {
            parsed[key] = value
            index++
        }
    }
    return parsed
}
