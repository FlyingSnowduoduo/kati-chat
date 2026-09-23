// 卡提聊天助手 · 本地服务 (Node.js 零依赖)
// 静态网页 + 双后端流式代理：
//   1) GPU 后端：llama.cpp 的 llama-server（Vulkan 加速，OpenAI 兼容 API） ← 优先
//   2) CPU 后端：Ollama（NDJSON API）                                      ← 兜底
// 前端只跟本服务说话，两种后端对它完全透明。
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const PUBLIC = path.join(__dirname, 'public')
const PORT = Number(process.env.WHALE_PORT || 7890)
const OLLAMA = process.env.OLLAMA_URL || 'http://127.0.0.1:11434'
const LLAMA = process.env.LLAMA_URL || 'http://127.0.0.1:8080'
const DEFAULT_MODEL = process.env.WHALE_MODEL || 'qwen2.5vl:7b'
const GPU_MODEL = 'qwen2.5-vl-7b'

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.woff2': 'font/woff2',
}

function sendJson(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(obj))
}

async function readBody(req) {
  let body = ''
  for await (const chunk of req) body += chunk
  return body
}

async function backendStatus() {
  let llama = false
  let ollama = false
  try { llama = (await fetch(LLAMA + '/health', { signal: AbortSignal.timeout(1500) })).ok } catch { /* 未启动 */ }
  try { ollama = (await fetch(OLLAMA + '/api/tags', { signal: AbortSignal.timeout(1500) })).ok } catch { /* 未启动 */ }
  return { llama, ollama }
}

/* ---------- 联网搜索 ---------- */
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function decodeEntities(s) {
  return String(s).replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/g, (m, e) => {
    if (e[0] === '#') {
      const code = (e[1] === 'x' || e[1] === 'X') ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10)
      return Number.isFinite(code) ? String.fromCodePoint(code) : m
    }
    const named = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', ensp: ' ', emsp: ' ', thinsp: ' ', middot: '·', hellip: '…', mdash: '—', ndash: '–', ldquo: '“', rdquo: '”' }
    return named[e] !== undefined ? named[e] : m
  })
}
function stripTags(s) {
  return decodeEntities(String(s).replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim()
}
function fetchWithTimeout(url, ms = 10000, headers = {}) {
  return fetch(url, {
    headers: Object.assign({ 'User-Agent': UA, 'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8' }, headers),
    signal: AbortSignal.timeout(ms),
    redirect: 'follow',
  })
}

// 从 Bing 搜索结果页提取条目
async function searchBing(query, n = 6) {
  const r = await fetchWithTimeout('https://cn.bing.com/search?q=' + encodeURIComponent(query) + '&setlang=zh-CN', 10000)
  const html = await r.text()
  const out = []
  for (const b of html.split(/<li class="b_algo"/).slice(1)) {
    const m = b.match(/<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i)
    if (!m) continue
    let link = m[1]
    const ck = link.match(/[?&]u=a1([^&]+)/)
    if (ck) { try { link = Buffer.from(decodeURIComponent(ck[1]), 'base64').toString('utf8') } catch { /* 保留原链接 */ } }
    const title = stripTags(m[2])
    let snippet = ''
    const sm = b.match(/<p[^>]*>([\s\S]*?)<\/p>/i)
    if (sm) snippet = stripTags(sm[1])
    if (title && /^https?:/i.test(link)) out.push({ title, snippet, url: link })
    if (out.length >= n) break
  }
  return out
}

// 百度兜底（GBK 编码）
async function searchBaidu(query, n = 6) {
  const r = await fetchWithTimeout('https://www.baidu.com/s?wd=' + encodeURIComponent(query), 10000)
  const buf = Buffer.from(await r.arrayBuffer())
  let html
  try { html = new TextDecoder('gbk').decode(buf) } catch { html = buf.toString('utf8') }
  const out = []
  for (const b of html.split(/<div class="result c-container/).slice(1)) {
    const m = b.match(/<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i)
    if (!m) continue
    const title = stripTags(m[2])
    let snippet = ''
    const sm = b.match(/<span class="content-right_[\w-]+">([\s\S]*?)<\/span>/i) || b.match(/<div[^>]*class="[^"]*c-abstract[^"]*"[^>]*>([\s\S]*?)<\/div>/i)
    if (sm) snippet = stripTags(sm[1])
    if (title) out.push({ title, snippet, url: m[1] })
    if (out.length >= n) break
  }
  return out
}

// 抓取网页正文摘要（处理 UTF-8/GBK）
async function fetchPageText(url, maxChars = 1500) {
  try {
    const r = await fetchWithTimeout(url, 9000)
    const buf = Buffer.from(await r.arrayBuffer())
    const ctype = r.headers.get('content-type') || ''
    let charset = (ctype.match(/charset=["']?([\w-]+)/i) || [])[1]
    if (!charset) charset = (buf.slice(0, 2048).toString('latin1').match(/charset=["']?([\w-]+)/i) || [])[1]
    charset = (charset || 'utf-8').toLowerCase()
    if (charset === 'gb2312' || charset === 'gb-2312') charset = 'gbk'
    let text
    try { text = new TextDecoder(charset, { fatal: false }).decode(buf) } catch { text = buf.toString('utf8') }
    text = text.replace(/<script[\s\S]*?<\/script>/gi, ' ').replace(/<style[\s\S]*?<\/style>/gi, ' ')
    return stripTags(text).slice(0, maxChars)
  } catch { return '' }
}

// 实时热榜（今日头条，失败则用百度热搜）
async function hotNews(limit = 12) {
  try {
    const r = await fetchWithTimeout('https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc', 9000)
    const j = await r.json()
    const list = (j.data || []).slice(0, limit).map((x) => ({ title: String(x.Title || '').trim(), url: x.Url || '' })).filter((x) => x.title)
    if (list.length) return list
  } catch { /* 用百度兜底 */ }
  try {
    const r = await fetchWithTimeout('https://top.baidu.com/api/board?platform=wise&tab=realtime', 9000)
    const j = await r.json()
    const out = []
    for (const card of ((j.data && j.data.cards) || [])) {
      for (const item of (card.content || [])) {
        const t = item.word || item.query || item.name || (item.content && item.content[0] && (item.content[0].word || item.content[0].query))
        if (t) out.push({ title: String(t).trim(), url: item.url || '' })
        if (out.length >= limit) break
      }
      if (out.length >= limit) break
    }
    return out
  } catch { return [] }
}

// 判断是否是需要实时热榜的问题
function isNewsIntent(text) {
  return /新闻|头条|热搜|热点|时事|大事|发生了?什么|新鲜事|最近怎么样|有什么消息/.test(String(text || ''))
}

async function webSearch(query) {
  let results = []
  try { results = await searchBing(query) } catch { /* 换百度 */ }
  if (!results.length) { try { results = await searchBaidu(query) } catch { /* 无结果 */ } }
  const top = results.slice(0, 2)
  await Promise.all(top.map(async (r) => { r.content = await fetchPageText(r.url) }))
  return results
}

// 把用户问题整理成更适合搜索引擎的关键词
function refineQuery(text) {
  let q = String(text).replace(/[？?！!。，,、；;：:"'“”‘’()（）\[\]【】]/g, ' ').replace(/\s+/g, ' ').trim()
  q = q.slice(0, 60)
  if (/新闻|最新|最近|今天|昨天|现在|当前|头条|进展|发布|价格|股价|比赛|比分|天气/.test(text)) {
    const d = new Date()
    q = `${q} ${d.getFullYear()}年${d.getMonth() + 1}月`
  }
  return q || String(text).slice(0, 60)
}

// 判断是否需要联网（时间敏感词）
function looksTimeSensitive(text) {
  if (!text) return false
  return /昨天|今天|明天|前天|后天|最新|最近|现在|当前|实时|新闻|头条|发生|股价|价格|多少钱|天气|气温|比分|赛程|结果|发布|上市|版本|更新|今年|明年|去年|本月|上月|本周|上周|这个月|这周|几号|日期|什么时候/.test(text)
}

function buildWebContext(results, hot) {
  const now = new Date()
  const stamp = now.toLocaleString('zh-CN', { hour12: false })
  const items = (results || []).map((r, i) => {
    const parts = [`[${i + 1}] ${r.title}`, r.snippet ? `摘要：${r.snippet}` : '', r.content ? `正文摘录：${r.content}` : '', `来源：${r.url}`]
    return parts.filter(Boolean).join('\n')
  }).join('\n\n')
  const hotBlock = (hot && hot.length)
    ? `【实时热榜（刚刚从网络抓取，就是当下的真实热点）】\n${hot.map((h, i) => `${i + 1}. ${h.title}`).join('\n')}\n\n`
    : ''
  return `【联网搜索结果】当前真实时间：${stamp}（这是系统提供的真实时间，你的训练数据可能滞后，` +
    `如果资料中的日期看起来比你的记忆更晚，那是正常的，请以资料为准，不要以“日期在未来”为由拒绝回答）。` +
    `请优先依据下面的资料回答用户问题；若资料与你的记忆冲突，以资料为准；若资料不足，请说明哪些信息无法确认。` +
    `回答末尾用「参考资料」列出你用到的来源编号。\n\n${hotBlock}${items ? '【网页搜索结果】\n' + items : ''}`
}

/* ---------- 格式转换 ---------- */

// 前端 parts 数组 -> OpenAI 格式（llama.cpp）
function toOpenAIMessages(messages) {
  return (messages || []).map((m) => {
    if (m && Array.isArray(m.content)) {
      const parts = []
      for (const p of m.content) {
        if (p && p.type === 'image' && p.image) {
          parts.push({ type: 'image_url', image_url: { url: 'data:image/jpeg;base64,' + p.image } })
        } else if (p && p.type === 'text' && p.text) {
          parts.push({ type: 'text', text: p.text })
        }
      }
      return { role: m.role, content: parts.length ? parts : '' }
    }
    return { role: m.role, content: m.content }
  })
}

// 前端 parts 数组 -> Ollama 格式（Ollama 0.34+ 要求 content 为字符串、图片放 images 字段）
function toOllamaMessages(messages) {
  return (messages || []).map((m) => {
    if (m && Array.isArray(m.content)) {
      const images = []
      let text = ''
      for (const part of m.content) {
        if (part && part.type === 'image' && part.image) images.push(part.image)
        else if (part && part.type === 'text' && part.text) text += (text ? '\n' : '') + part.text
      }
      const out = { role: m.role, content: text }
      if (images.length) out.images = images
      return out
    }
    return m
  })
}

/* ---------- GPU 后端：llama.cpp (OpenAI 兼容，SSE 流转 NDJSON) ---------- */
async function chatLlama(req, res, payload) {
  const opts = payload.options || {}
  const body = {
    model: GPU_MODEL,
    messages: toOpenAIMessages(payload.messages),
    stream: true,
    max_tokens: opts.num_predict || 450,
    temperature: typeof opts.temperature === 'number' ? opts.temperature : 0.7,
    cache_prompt: true,
  }

  res.writeHead(200, {
    'Content-Type': 'application/x-ndjson; charset=utf-8',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
  })
  if (payload.__sources && payload.__sources.length) {
    res.write(JSON.stringify({ sources: payload.__sources }) + '\n')
  }

  let upstream
  try {
    upstream = await fetch(LLAMA + '/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
  } catch (e) {
    res.write(JSON.stringify({ error: '无法连接 GPU 推理服务（llama.cpp），请重新双击桌面图标' }) + '\n')
    res.end()
    return
  }

  if (!upstream.ok || !upstream.body) {
    const t = (await upstream.text().catch(() => '')).slice(0, 500)
    res.write(JSON.stringify({ error: `llama.cpp ${upstream.status}: ${t}` }) + '\n')
    res.end()
    return
  }

  const reader = upstream.body.getReader()
  const decoder = new TextDecoder()
  const abortStream = () => reader.cancel().catch(() => {})
  req.on('close', abortStream)
  let finish = null
  try {
    let buf = ''
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buf += decoder.decode(value, { stream: true })
      const lines = buf.split('\n')
      buf = lines.pop()
      for (const line of lines) {
        const t = line.trim()
        if (!t.startsWith('data:')) continue
        const data = t.slice(5).trim()
        if (!data || data === '[DONE]') continue
        let obj
        try { obj = JSON.parse(data) } catch { continue }
        const choice = obj.choices && obj.choices[0]
        if (!choice) continue
        if (choice.finish_reason) finish = choice.finish_reason
        const content = choice.delta && choice.delta.content
        if (content) res.write(JSON.stringify({ message: { content } }) + '\n')
      }
    }
    res.write(JSON.stringify({ done: true, done_reason: finish === 'length' ? 'length' : 'stop' }) + '\n')
  } finally {
    req.off('close', abortStream)
    res.end()
  }
}

/* ---------- CPU 后端：Ollama（NDJSON 原样转发） ---------- */
async function chatOllama(req, res, payload) {
  const upstreamBody = {
    model: payload.model || DEFAULT_MODEL,
    messages: toOllamaMessages(payload.messages),
    stream: true,
    keep_alive: payload.keep_alive || '1h',
    options: Object.assign({ num_ctx: 4096, temperature: 0.7 }, payload.options || {}),
  }

  res.writeHead(200, {
    'Content-Type': 'application/x-ndjson; charset=utf-8',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
  })
  if (payload.__sources && payload.__sources.length) {
    res.write(JSON.stringify({ sources: payload.__sources }) + '\n')
  }

  let upstream
  try {
    upstream = await fetch(OLLAMA + '/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(upstreamBody),
    })
  } catch (e) {
    res.write(JSON.stringify({ error: '无法连接本地模型服务(Ollama)，请确认其已启动' }) + '\n')
    res.end()
    return
  }

  if (!upstream.ok || !upstream.body) {
    const t = (await upstream.text().catch(() => '')).slice(0, 500)
    res.write(JSON.stringify({ error: `Ollama ${upstream.status}: ${t}` }) + '\n')
    res.end()
    return
  }

  const reader = upstream.body.getReader()
  const decoder = new TextDecoder()
  const abortStream = () => reader.cancel().catch(() => {})
  req.on('close', abortStream)
  try {
    let buf = ''
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buf += decoder.decode(value, { stream: true })
      const lines = buf.split('\n')
      buf = lines.pop()
      for (const line of lines) {
        if (line.trim()) res.write(line + '\n')
      }
    }
    if (buf.trim()) res.write(buf.trim() + '\n')
  } finally {
    req.off('close', abortStream)
    res.end()
  }
}

/* ---------- HTTP 服务 ---------- */
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1')

    // ---------- 健康状态 ----------
    if (url.pathname === '/api/health' && req.method === 'GET') {
      const st = await backendStatus()
      sendJson(res, 200, {
        ok: true,
        ready: st.llama || st.ollama,
        llama: st.llama,     // GPU 后端
        ollama: st.ollama,   // CPU 兜底
        backend: st.llama ? 'gpu' : (st.ollama ? 'cpu' : 'none'),
        model: st.llama ? GPU_MODEL : DEFAULT_MODEL,
      })
      return
    }

    // ---------- 模型列表 ----------
    if (url.pathname === '/api/tags' && req.method === 'GET') {
      const st = await backendStatus()
      const models = []
      if (st.llama) models.push({ name: GPU_MODEL, label: `${GPU_MODEL} · GPU 加速 🚀`, backend: 'gpu' })
      if (st.ollama) {
        try {
          const j = await (await fetch(OLLAMA + '/api/tags')).json()
          for (const m of (j.models || [])) models.push({ name: m.name, label: `${m.name} · CPU`, backend: 'cpu' })
        } catch { /* ignore */ }
      }
      sendJson(res, 200, { models })
      return
    }

    // ---------- 联网搜索（测试/手动调用） ----------
    if (url.pathname === '/api/search' && req.method === 'GET') {
      const q = url.searchParams.get('q') || ''
      if (!q) { sendJson(res, 400, { error: '缺少 q 参数' }); return }
      try {
        const results = await webSearch(q)
        sendJson(res, 200, { query: q, count: results.length, results })
      } catch (e) {
        sendJson(res, 500, { error: String(e.message || e) })
      }
      return
    }

    // ---------- 对话 ----------
    if (url.pathname === '/api/chat' && req.method === 'POST') {
      let payload
      try { payload = JSON.parse(await readBody(req)) } catch { sendJson(res, 400, { error: '无效的请求体' }); return }

      // 联网搜索：web = 'off' | 'auto' | 'on'
      const webMode = String(payload.web || 'off')
      const msgs = payload.messages || []
      const lastUser = [...msgs].reverse().find((m) => m && m.role === 'user')
      let userText = ''
      if (lastUser) {
        if (Array.isArray(lastUser.content)) {
          userText = lastUser.content.filter((p) => p && p.type === 'text').map((p) => p.text).join(' ')
        } else {
          userText = String(lastUser.content || '')
        }
      }
      const willSearch = !!userText && (webMode === 'on' || (webMode === 'auto' && looksTimeSensitive(userText)))
      let sources = []
      if (willSearch) {
        try {
          const newsWanted = isNewsIntent(userText)
          const [results, hot] = await Promise.all([
            webSearch(refineQuery(userText)).catch(() => []),
            newsWanted ? hotNews() : Promise.resolve([]),
          ])
          if (results.length || hot.length) {
            sources = [
              ...hot.map((h) => ({ title: h.title, url: h.url })),
              ...results.map((r) => ({ title: r.title, url: r.url })),
            ]
            msgs.push({ role: 'system', content: buildWebContext(results, hot) })
          }
        } catch { /* 搜索失败则正常回答 */ }
      }
      payload.messages = msgs
      payload.__sources = sources

      const st = await backendStatus()
      const modelName = String(payload.model || '')
      const useGpu = st.llama && (modelName === GPU_MODEL || modelName === '' || !st.ollama)

      if (useGpu) await chatLlama(req, res, payload)
      else if (st.ollama) await chatOllama(req, res, payload)
      else if (st.llama) await chatLlama(req, res, payload)
      else sendJson(res, 503, { error: '没有可用的推理后端，请重新双击桌面图标启动' })
      return
    }

    // ---------- 停止服务 ----------
    if (url.pathname === '/api/shutdown' && req.method === 'POST') {
      sendJson(res, 200, { ok: true, bye: '卡提去休息啦～' })
      setTimeout(() => process.exit(0), 300)
      return
    }

    // ---------- 静态文件 ----------
    let p = decodeURIComponent(url.pathname)
    if (p === '/') p = '/index.html'
    const file = path.normalize(path.join(PUBLIC, p))
    if (!file.startsWith(PUBLIC + path.sep) && file !== path.join(PUBLIC, 'index.html')) {
      sendJson(res, 403, { error: '禁止访问' })
      return
    }
    const data = fs.readFileSync(file)
    const ext = path.extname(file).toLowerCase()
    res.writeHead(200, {
      'Content-Type': MIME[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store, must-revalidate',
    })
    res.end(data)
  } catch (e) {
    if (e.code === 'ENOENT') { sendJson(res, 404, { error: '未找到资源' }); return }
    if (!res.headersSent) sendJson(res, 500, { error: String(e.message || e) })
    else res.end()
  }
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[卡提聊天助手] 已启动: http://127.0.0.1:${PORT}  (GPU 后端: ${LLAMA} / CPU 兜底: ${OLLAMA})`)
})
