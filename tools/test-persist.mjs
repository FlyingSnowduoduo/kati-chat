// 用 CDP 驱动无头 Edge，端到端验证「聊天记录持久化」与「清空记录」功能
import { spawn } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'

const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
const PORT = 9333
const APP = 'http://127.0.0.1:7890/?v=4'
const profile = mkdtempSync(path.join(tmpdir(), 'edge-cdp-'))
const child = spawn(EDGE, [
  '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
  `--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`,
  '--window-size=1200,900', 'about:blank',
], { stdio: 'ignore' })

const sleep = (ms) => new Promise(r => setTimeout(r, ms))

async function getPageTarget() {
  for (let i = 0; i < 40; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`)
      const list = await r.json()
      const p = list.find(t => t.type === 'page' && t.webSocketDebuggerUrl)
      if (p) return p
    } catch { /* not ready */ }
    await sleep(500)
  }
  throw new Error('无法连接 Edge 调试端口')
}

let result = { error: '未执行' }
try {
  const target = await getPageTarget()
  const ws = new WebSocket(target.webSocketDebuggerUrl)
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej })

  let msgId = 0
  const pending = new Map()
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data)
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id) }
  }
  const send = (method, params = {}) => new Promise((resolve) => {
    const id = ++msgId
    pending.set(id, resolve)
    ws.send(JSON.stringify({ id, method, params }))
  })
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    return r.result && r.result.result ? r.result.result.value : undefined
  }

  await send('Page.enable')
  await send('Page.navigate', { url: APP })
  await sleep(2600)

  const initialMessages = await evaluate(`document.querySelectorAll('.msg').length`)
  const controls = await evaluate(`JSON.stringify({ answerLen: !!document.querySelector('#answerLen'), clearBtn: !!document.querySelector('#clearBtn'), model: !!document.querySelector('#model'), composer: !!document.querySelector('#sendBtn') })`)
  const healthDot = await evaluate(`(document.querySelector('#dot')||{}).className`)

  // 写入一条历史记录，刷新后应自动恢复
  await evaluate(`localStorage.setItem('whale_history_v1', JSON.stringify([
    { role: 'user', text: 'Please translate this sentence.', thumbs: [] },
    { role: 'assistant', text: '这是一条历史记录，应该被恢复。', thumbs: [] }
  ]))`)
  await send('Page.navigate', { url: APP })
  await sleep(2600)
  const restoredCount = await evaluate(`document.querySelectorAll('.msg').length`)
  const restoredText = await evaluate(`document.body.innerText.includes('这是一条历史记录')`)
  const restoredUserText = await evaluate(`document.body.innerText.includes('Please translate this sentence.')`)

  // 清空按钮（覆盖 confirm 使其返回 true）
  await evaluate(`window.confirm = () => true; document.querySelector('#clearBtn').click()`)
  await sleep(900)
  const afterClearCount = await evaluate(`document.querySelectorAll('.msg').length`)
  const storeCleared = await evaluate(`localStorage.getItem('whale_history_v1') === null`)
  const welcomeBack = await evaluate(`document.body.innerText.includes('我是卡提')`)

  result = {
    initialMessages, controls, healthDot,
    restoredCount, restoredText, restoredUserText,
    afterClearCount, storeCleared, welcomeBack,
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
