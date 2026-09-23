// 验证悬浮快速窗口（quick.html）能正常聊天
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
const PORT = 9344
const URL = 'http://127.0.0.1:7890/quick.html'
const profile = mkdtempSync(path.join(tmpdir(), 'edge-quick-'))
const child = spawn(EDGE, [
  '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
  '--window-size=800,460', 'about:blank',
], { stdio: 'ignore' })
const sleep = (ms) => new Promise(r => setTimeout(r, ms))

let result = { error: '未执行' }
try {
  let target = null
  for (let i = 0; i < 40 && !target; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()
      target = list.find(t => t.type === 'page' && t.webSocketDebuggerUrl)
    } catch { /* not ready */ }
    if (!target) await sleep(500)
  }
  if (!target) throw new Error('无法连接调试端口')

  const ws = new WebSocket(target.webSocketDebuggerUrl)
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })
  let id = 0
  const pending = new Map()
  ws.onmessage = (ev) => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) } }
  const send = (method, params = {}) => new Promise((resolve) => { const i = ++id; pending.set(i, resolve); ws.send(JSON.stringify({ id: i, method, params })) })
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    return r.result && r.result.result ? r.result.result.value : undefined
  }

  await send('Page.enable')
  await send('Page.navigate', { url: URL })
  await sleep(2000)

  const ui = await evaluate(`JSON.stringify({ input: !!document.querySelector('#q'), send: !!document.querySelector('#go'), out: !!document.querySelector('#out'), mic: !!document.querySelector('#micBtn'), web: !!document.querySelector('#webBtn'), placeholder: (document.querySelector('#q')||{}).placeholder })`)

  // 模拟输入并回车发送
  await evaluate(`(function(){ var q = document.querySelector('#q'); q.value = '用一句话介绍你自己'; q.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })); return 'sent' })()`)

  // 等待流式回答
  let answer = ''
  for (let i = 0; i < 40; i++) {
    await sleep(1000)
    answer = await evaluate(`(document.querySelector('#out')||{}).innerText || ''`)
    if (answer && !answer.includes('思考中') && answer.length > 8) break
  }

  result = {
    ui: JSON.parse(ui || '{}'),
    answerLength: String(answer || '').length,
    answerPreview: String(answer || '').slice(0, 160),
    ok: String(answer || '').length > 8,
  }
  ws.close()
} catch (e) {
  result = { error: String(e && e.message || e) }
}
console.log(JSON.stringify(result, null, 2))
try { child.kill() } catch { /* ignore */ }
await sleep(600)
try { rmSync(profile, { recursive: true, force: true }) } catch { /* ignore */ }
process.exit(0)
