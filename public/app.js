/* 卡提聊天助手 · 前端逻辑 */
const $ = (s) => document.querySelector(s)

const DEFAULT_MODEL = 'qwen2.5-vl-7b'
const SYSTEM_PROMPT = `你是「卡提」，一位住在深海的可爱鲸鱼 AI 助手，同时是一名专业的英汉翻译与英语教学专家。请遵守以下规则：
1. 当用户发送图片时：逐字识别图片中的所有英文文字（段落、截图、招牌、标语都要完整识别，不要遗漏），然后按以下结构输出：
   - 【原文】：识别出的英文原文（保留段落结构）
   - 【翻译】：逐句中文翻译
   - 【单词与词组详解】：解释每个重点单词/词组（音标、词性、中文含义、常见搭配、一个例句）
2. 当用户要求翻译一段文字时：给出逐句翻译，并解释句子中的重点单词和词组。
3. 平时与用户用中文自然聊天，语气亲切可爱；能协助日常办公（写邮件、润色、总结、头脑风暴、日程安排等）。
4. 回答使用 Markdown 排版，条理清晰。`

const WELCOME = `🐋 你好呀～我是**卡提**，你的本地 AI 聊天助手！

我能帮你：
1. **📷 识别图片里的英文并翻译** — 直接粘贴截图、拖入图片，我会逐句翻译并详解重点单词词组；
2. **📖 详细翻译文字** — 附单词、词组、语法讲解；
3. **✉️ 办公协助** — 写邮件、润色、总结等；
4. **💬 日常聊天** — 陪你聊天解闷～

所有内容都在**你自己的电脑上运行**，不联网、不上传，隐私无忧。来试试吧！`

/* ---------- 配置 ---------- */
const STORE_KEY = 'whale_history_v1'
const MAX_STORED = 40      // 本地最多保存的消息条数
const MAX_SEND = 12        // 每次发给模型的最大历史条数（越少越快）
const IMG_MAX = 1024       // 送入模型的图片最长边（越小越快）

let model = localStorage.getItem('whale_model') || DEFAULT_MODEL
let answerMode = localStorage.getItem('whale_answer_mode') || 'normal'
let webMode = localStorage.getItem('whale_web_mode') || 'auto'
let forceWeb = false   // 🌐 按钮：本条消息强制联网
const ANSWER_MODES = {
  brief: { num_predict: 200, label: '简洁（最快）' },
  normal: { num_predict: 450, label: '标准' },
  rich: { num_predict: 1000, label: '详细（较慢）' },
}

let history = []        // {role, text, images?, thumbs?}
let pendingImages = []  // base64（无前缀）待发送图片
let isBusy = false
let abortCtrl = null

const chatEl = $('#chat')
const inputEl = $('#input')
const sendBtn = $('#sendBtn')
const thumbsEl = $('#thumbs')
const fileInput = $('#fileInput')

/* ---------- markdown-lite 渲染（安全转义） ---------- */
function esc(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}
function renderMd(s) {
  let h = esc(s)
  h = h.replace(/```([\s\S]*?)```/g, (m, c) => `<pre><code>${c.trim()}</code></pre>`)
  h = h.replace(/`([^`\n]+)`/g, '<code>$1</code>')
  h = h.replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>')
  h = h.replace(/^#{1,4}\s+(.*)$/gm, '<div class="md-h">$1</div>')
  h = h.replace(/^\s*[-*•]\s+(.*)$/gm, '<div class="md-li"><span class="dot">•</span>$1</div>')
  h = h.replace(/^\s*(\d+)[.)]\s+(.*)$/gm, '<div class="md-li"><span class="dot">$1.</span>$2</div>')
  h = h.replace(/\n{2,}/g, '<br><br>').replace(/\n/g, '<br>')
  return h
}

/* ---------- 消息气泡 ---------- */
function scrollBottom() { chatEl.scrollTop = chatEl.scrollHeight }

function addBubble(role, opts = {}) {
  const el = document.createElement('div')
  el.className = 'msg ' + role
  const body = document.createElement('div')
  body.className = 'bubble'
  el.appendChild(body)
  chatEl.appendChild(el)
  const b = {
    el, body,
    text: '',
    error: '',
    images: opts.images || [],
    sources: opts.sources || [],
    typing: false,
    render() {
      let html = ''
      if (b.images.length) {
        html += '<div class="imgs">' + b.images.map(x => `<img src="data:image/jpeg;base64,${x}" alt="图片">`).join('') + '</div>'
      }
      if (b.sources.length) {
        html += '<div class="sources">🔗 参考资料：' + b.sources.map((s, i) =>
          `<a href="${esc(s.url)}" target="_blank" rel="noreferrer">[${i + 1}] ${esc(String(s.title || s.url).slice(0, 38))}</a>`).join('') + '</div>'
      }
      if (b.typing && !b.text) {
        html += '<div class="typing"><span></span><span></span><span></span></div>'
      } else if (b.error && !b.text) {
        html += `<div class="err">⚠️ ${esc(b.error)}</div>`
      } else {
        html += `<div class="txt">${renderMd(b.text)}</div>`
      }
      body.innerHTML = html
      scrollBottom()
    },
  }
  if (opts.text) { b.text = opts.text; b.render() }
  return b
}

function friendlyError(msg) {
  if (!msg) return '发生未知错误，请重试'
  const m = String(msg)
  if (m.includes('model') && (m.includes('not found') || m.includes('not exist'))) {
    return '模型未就绪。请重新双击桌面「卡提聊天助手」图标，启动 GPU 推理服务。'
  }
  if (m.includes('无法连接') || m.includes('fetch failed') || m.includes('ECONNREFUSED')) {
    return '无法连接本地推理服务，请重新双击桌面「卡提聊天助手」图标。'
  }
  return m.slice(0, 300)
}

/* ---------- 聊天记录持久化 ---------- */
function persist() {
  const slim = (withThumbs) => history.slice(-MAX_STORED).map(m => ({
    role: m.role,
    text: m.text || '',
    thumbs: withThumbs ? (m.thumbs || []) : [],
  }))
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(slim(true)))
  } catch (e) {
    // 空间不足（图片缩略图过多）→ 只存文字
    try { localStorage.setItem(STORE_KEY, JSON.stringify(slim(false))) } catch (e2) { /* 放弃保存 */ }
  }
}

function restoreHistory() {
  try {
    const raw = localStorage.getItem(STORE_KEY)
    if (!raw) return false
    const arr = JSON.parse(raw)
    if (!Array.isArray(arr) || arr.length === 0) return false
    history = arr.map(m => ({
      role: m.role === 'user' ? 'user' : 'assistant',
      text: m.text || '',
      thumbs: m.thumbs || [],
    }))
    for (const m of history) addBubble(m.role, { text: m.text, images: m.thumbs })
    return true
  } catch { return false }
}

function clearHistory() {
  if (isBusy) { alert('正在生成回答，请等生成结束或点「停止」后再清空。'); return }
  if (!confirm('清空全部聊天记录？\n\n· 之前的对话会从本机删除\n· 此操作不可撤销（Ollama 模型本身不受影响）')) return
  try { localStorage.removeItem(STORE_KEY) } catch (e) { /* ignore */ }
  history = []
  chatEl.innerHTML = ''
  addBubble('assistant', { text: WELCOME })
  inputEl.focus()
}

/* ---------- 图片处理 ---------- */
function readFileAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader()
    fr.onload = () => resolve(fr.result)
    fr.onerror = reject
    fr.readAsDataURL(file)
  })
}
function loadImage(src) {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = src
  })
}
async function fileToB64(file) {
  const dataUrl = await readFileAsDataURL(file)
  const img = await loadImage(dataUrl)
  const scale = Math.min(1, IMG_MAX / Math.max(img.width, img.height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(img.width * scale))
  canvas.height = Math.max(1, Math.round(img.height * scale))
  canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height)
  return canvas.toDataURL('image/jpeg', 0.85).split(',')[1]
}

// 生成小缩略图，用于保存聊天记录（避免占满浏览器存储）
async function makeThumb(b64) {
  try {
    const img = await loadImage('data:image/jpeg;base64,' + b64)
    const MAX = 150
    const scale = Math.min(1, MAX / Math.max(img.width, img.height))
    const c = document.createElement('canvas')
    c.width = Math.max(1, Math.round(img.width * scale))
    c.height = Math.max(1, Math.round(img.height * scale))
    c.getContext('2d').drawImage(img, 0, 0, c.width, c.height)
    return c.toDataURL('image/jpeg', 0.6).split(',')[1]
  } catch { return '' }
}

async function addFiles(files) {
  for (const f of Array.from(files || [])) {
    if (!f.type.startsWith('image/')) continue
    try {
      const b64 = await fileToB64(f)
      pendingImages.push(b64)
    } catch (e) { /* ignore */ }
  }
  renderThumbs()
}
function renderThumbs() {
  thumbsEl.innerHTML = ''
  pendingImages.forEach((b64, i) => {
    const d = document.createElement('div')
    d.className = 'thumb'
    d.innerHTML = `<img src="data:image/jpeg;base64,${b64}"><button class="rm" title="移除">✕</button>`
    d.querySelector('.rm').onclick = () => { pendingImages.splice(i, 1); renderThumbs() }
    thumbsEl.appendChild(d)
  })
}

/* ---------- 发送 ---------- */
function updateSendBtn() {
  sendBtn.disabled = isBusy
  sendBtn.textContent = isBusy ? '停止 ⏹' : '发送 ⬆'
}

async function send() {
  if (isBusy) { if (abortCtrl) abortCtrl.abort(); return }
  const text = inputEl.value.trim()
  if (!text && pendingImages.length === 0) return

  let sendText = text
  if (!sendText && pendingImages.length > 0) {
    sendText = '请识别图片中的所有英文文字，逐句翻译成中文，并详细解释每句中的重点单词和词组（音标、词性、含义、例句）。'
  }

  const images = pendingImages.slice()
  pendingImages = []
  renderThumbs()
  inputEl.value = ''
  autoResize()

  addBubble('user', { text, images })
  const thumbs = []
  for (const b of images) thumbs.push(await makeThumb(b))
  history.push({ role: 'user', text: sendText, images, thumbs })
  persist()

  const assistant = addBubble('assistant', {})
  assistant.typing = true
  assistant.render()

  isBusy = true
  updateSendBtn()
  abortCtrl = new AbortController()

  // 只发送最近若干条历史（越短的提示词越快），图片只带在最后一条用户消息里
  const recent = history.slice(-MAX_SEND)
  const baseIndex = history.length - recent.length
  const msgs = [{ role: 'system', content: SYSTEM_PROMPT }]
  recent.forEach((m, i) => {
    const globalIndex = baseIndex + i
    if (m.role === 'user') {
      const parts = []
      if (globalIndex === history.length - 1 && m.images && m.images.length) {
        for (const b of m.images) parts.push({ type: 'image', image: b })
      }
      if (m.text) parts.push({ type: 'text', text: m.text })
      if (parts.length) msgs.push({ role: 'user', content: parts })
    } else if (m.text) {
      msgs.push({ role: 'assistant', content: m.text })
    }
  })

  let full = ''
  let truncated = false
  try {
    const resp = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages: msgs,
        keep_alive: '1h',
        web: forceWeb ? 'on' : webMode,
        options: { num_predict: (ANSWER_MODES[answerMode] || ANSWER_MODES.normal).num_predict },
      }),
      signal: abortCtrl.signal,
    })
    if (!resp.ok) throw new Error('HTTP ' + resp.status)
    const reader = resp.body.getReader()
    const dec = new TextDecoder()
    let buf = ''
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      buf += dec.decode(value, { stream: true })
      const lines = buf.split('\n')
      buf = lines.pop()
      for (const line of lines) {
        if (!line.trim()) continue
        let obj
        try { obj = JSON.parse(line) } catch { continue }
        if (obj.error) throw new Error(obj.error)
        if (obj.sources && obj.sources.length) {
          assistant.sources = obj.sources
          assistant.render()
        }
        if (obj.done && obj.done_reason === 'length') truncated = true
        if (obj.message && obj.message.content) {
          full += obj.message.content
          assistant.text = full
          assistant.typing = false
          assistant.render()
        }
      }
    }
    if (!full) throw new Error('模型返回了空回复，请重试')
    history.push({ role: 'assistant', text: full })
    persist()
    if (truncated) {
      const note = document.createElement('div')
      note.className = 'note'
      note.textContent = '⚠️ 回答达到长度上限。想更完整可把右上角「回答长度」调到「详细」，或直接追问「继续」。'
      assistant.body.appendChild(note)
    }
  } catch (e) {
    if (e.name === 'AbortError') {
      if (full) {
        assistant.text = full
        history.push({ role: 'assistant', text: full })
        persist()
      } else {
        assistant.error = '已停止生成'
      }
    } else {
      assistant.error = friendlyError(e.message)
    }
    assistant.typing = false
    assistant.render()
  } finally {
    isBusy = false
    abortCtrl = null
    forceWeb = false
    const wc = $('#webChip')
    if (wc) wc.classList.remove('on')
    updateSendBtn()
    inputEl.focus()
  }
}

/* ---------- 快捷指令 ---------- */
const CHIP_PROMPTS = {
  img: '请识别图片中的所有英文文字，逐句翻译成中文，并详细解释每句中的重点单词和词组（音标、词性、含义、例句）。',
  detail: '请详细翻译下面这段英文：逐句给出翻译，并解释每句中的重点单词和词组（音标、词性、含义、例句）。\n\n',
  words: '请详细解释下面这些单词和词组：音标、词性、中文含义、常见搭配，并各给一个例句。\n\n',
  mail: '请帮我把下面的邮件润色得更专业、礼貌，同时保留原意：\n\n',
  chat: '我们像朋友一样聊聊天吧～（用中文，语气亲切）',
}
document.querySelectorAll('.chip').forEach(chip => {
  chip.addEventListener('click', () => {
    const mode = chip.dataset.mode
    if (mode === 'web') {
      forceWeb = !forceWeb
      chip.classList.toggle('on', forceWeb)
      inputEl.placeholder = forceWeb ? '🌐 已开启联网：输入问题后发送' : '输入要翻译的文字，或粘贴 / 拖入图片…'
      inputEl.focus()
      return
    }
    if (mode === 'img' && pendingImages.length === 0) {
      fileInput.click()
      inputEl.value = CHIP_PROMPTS.img
      autoResize()
      return
    }
    if (inputEl.value.trim()) inputEl.value += '\n\n'
    inputEl.value += CHIP_PROMPTS[mode]
    inputEl.focus()
    autoResize()
  })
})

/* ---------- 输入区 ---------- */
function autoResize() {
  inputEl.style.height = 'auto'
  inputEl.style.height = Math.min(inputEl.scrollHeight, 160) + 'px'
}
inputEl.addEventListener('input', autoResize)
inputEl.addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); send() }
})
sendBtn.addEventListener('click', send)

$('#attachBtn').addEventListener('click', () => fileInput.click())
fileInput.addEventListener('change', () => { addFiles(fileInput.files); fileInput.value = '' })

const clearBtn = $('#clearBtn')
if (clearBtn) clearBtn.addEventListener('click', clearHistory)

const lenSel = $('#answerLen')
if (lenSel) {
  lenSel.value = answerMode
  lenSel.addEventListener('change', () => {
    answerMode = lenSel.value
    localStorage.setItem('whale_answer_mode', answerMode)
  })
}

const webSel = $('#webMode')
if (webSel) {
  webSel.value = webMode
  webSel.addEventListener('change', () => {
    webMode = webSel.value
    localStorage.setItem('whale_web_mode', webMode)
  })
}

document.addEventListener('paste', e => {
  const items = e.clipboardData && e.clipboardData.items
  if (!items) return
  const files = []
  for (const it of items) {
    if (it.type.startsWith('image/')) {
      const f = it.getAsFile()
      if (f) files.push(f)
    }
  }
  if (files.length) { e.preventDefault(); addFiles(files) }
})

document.addEventListener('dragover', e => { e.preventDefault() })
document.addEventListener('drop', e => {
  e.preventDefault()
  if (e.dataTransfer && e.dataTransfer.files.length) addFiles(e.dataTransfer.files)
})

/* ---------- 语音输入 ---------- */
const micBtn = $('#micBtn')
let rec = null
let listening = false
if (window.SpeechRecognition || window.webkitSpeechRecognition) {
  rec = new (window.SpeechRecognition || window.webkitSpeechRecognition)()
  rec.lang = 'zh-CN'
  rec.continuous = false
  rec.interimResults = true
  rec.onresult = e => {
    let t = ''
    for (const r of e.results) t += r[0].transcript
    inputEl.value = t
    autoResize()
  }
  const stopUi = () => { listening = false; micBtn.classList.remove('on') }
  rec.onend = stopUi
  rec.onerror = stopUi
} else {
  micBtn.title = '当前浏览器不支持语音输入（请用 Edge / Chrome）'
  micBtn.style.opacity = '.4'
}
micBtn.addEventListener('click', () => {
  if (!rec) return
  if (listening) { rec.stop(); return }
  try { rec.start() } catch { return }
  listening = true
  micBtn.classList.add('on')
  inputEl.placeholder = '🎤 正在聆听，请说话…'
  setTimeout(() => { inputEl.placeholder = '输入要翻译的文字，或粘贴 / 拖入图片…' }, 8000)
})

/* ---------- 模型选择 / 服务状态 ---------- */
const sel = $('#model')
const dot = $('#dot')
const banner = $('#banner')

async function loadModels() {
  try {
    const r = await fetch('/api/tags')
    const j = await r.json()
    const labelOf = (n) => {
      if (/3b/i.test(n)) return n + ' · 快 2 倍'
      if (/7b/i.test(n)) return n + ' · 质量高'
      return n
    }
    const list = (j.models || []).map(m => (typeof m === 'string' ? { name: m } : m))
    const names = list.map(m => m.name)
    sel.innerHTML = ''
    for (const m of list) {
      const o = document.createElement('option')
      o.value = m.name
      o.textContent = m.label || labelOf(m.name)
      sel.appendChild(o)
    }
    if (names.length && !names.includes(model)) model = names[0]
    if (!names.length) {
      const o = document.createElement('option')
      o.value = DEFAULT_MODEL
      o.textContent = DEFAULT_MODEL + '（下载中）'
      sel.appendChild(o)
    }
    sel.value = model
  } catch { /* 服务未启动 */ }
}
sel.addEventListener('change', () => {
  model = sel.value
  localStorage.setItem('whale_model', model)
})

let serviceWasDown = false

async function health() {
  try {
    const r = await fetch('/api/health')
    const h = await r.json()
    const ready = h.ready !== undefined ? h.ready : h.ollama
    dot.className = 'dot ' + (ready ? 'ok' : 'warn')
    dot.title = h.backend === 'gpu' ? 'GPU 加速中 🚀' : (h.backend === 'cpu' ? 'CPU 模式（较慢）' : '服务未就绪')
    banner.hidden = ready
    if (ready && banner.dataset.first !== '1') {
      banner.dataset.first = '1'
      loadModels()
    }
    if (serviceWasDown) {
      serviceWasDown = false
      location.reload()
      return
    }
  } catch {
    dot.className = 'dot down'
    banner.hidden = false
    serviceWasDown = true
  }
}

/* ---------- 启动 ---------- */
if (!restoreHistory()) addBubble('assistant', { text: WELCOME })
health()
setInterval(health, 5000)
loadModels()
inputEl.focus()
