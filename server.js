"use strict"

const http = require("http")
const crypto = require("crypto")
const { Readable, Transform } = require("stream")
const { pipeline } = require("stream/promises")
const path = require("path")
const fs = require("fs")

const PORT = Number(process.env.PORT) || 8080
const PUBLIC_DIR = path.join(__dirname, "public")
const API_KEY = "WaDl-2026-9F2C8E4B1A7D6F03C5B9E2A48D1F7A92"
const COOKIES_FILE = path.join(__dirname, "cookies.txt")
let cookiesHash = null
let cookiesSyncing = false

// Ordine: pubblico prima (Render lo raggiunge), LAN come ripiego.
// La VM non raggiunge il proprio IP pubblico sulla porta 80 (NAT hairpin),
// quindi li serve il secondo: il probe con timeout breve decide chi usare.
const API_BASES = (process.env.API_BASES
  ? process.env.API_BASES.split(",")
  : ["http://82.223.13.114:81", "http://192.168.100.14:81"]
).map((s) => s.trim()).filter(Boolean)

const PROBE_MS = Number(process.env.PROBE_MS) || 4000
let preferred = 0
let probeTimer = null

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
}

const SERVER_START = Date.now()

function sendJson(res, status, payload) {
  res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" })
  res.end(JSON.stringify(payload))
}

function serveStatic(req, res, pathname) {
  const rel = pathname === "/" ? "index.html" : pathname.slice(1)
  const abs = path.join(PUBLIC_DIR, path.normalize(rel).replace(/^(\.\.[/\\])+/, ""))
  if (!abs.startsWith(PUBLIC_DIR)) {
    res.writeHead(403)
    return res.end("403")
  }
  fs.createReadStream(abs)
    .on("error", () => { res.writeHead(404); res.end("404") })
    .on("open", () => {
      const ext = path.extname(abs).toLowerCase()
      res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" })
    })
    .pipe(res)
}

// Sonda tutte le basi con timeout corto: la prima che risponde diventa
// la preferita. Senza questo, il tentativo sbagliato penderebbe per
// decine di secondi su ogni richiesta.
async function probeBases(reason) {
  const order = [preferred, ...API_BASES.map((_, i) => i).filter((i) => i !== preferred)]

  for (const i of order) {
    if (API_BASES.length === 1) break
    let ok = false
    try {
      const ctrl = new AbortController()
      const t = setTimeout(() => ctrl.abort(), PROBE_MS)
      const r = await fetch(`${API_BASES[i]}/api/download/health`, {
        headers: { "X-API-Key": API_KEY },
        signal: ctrl.signal,
      })
      clearTimeout(t)
      ok = r.ok
      if (r.body) await r.body.cancel().catch(() => {})
    } catch {
      ok = false
    }

    if (ok) {
      if (preferred !== i) {
        console.log(`[probe] base attiva: ${API_BASES[i]} (motivo: ${reason})`)
        preferred = i
      }
      return preferred
    }
  }

  console.warn(`[probe] nessuna base risponde (${reason})`)
  return preferred
}

function scheduleProbe() {
  clearTimeout(probeTimer)
  probeTimer = setTimeout(async () => {
    await probeBases("periodico")
    scheduleProbe()
  }, 60000)
}

// Legge cookies.txt dalla root del progetto e, se cambiato rispetto all'ultimo
// invio, lo spinge all'API (POST /api/download/cookies) così yt-dlp lo riusa
// sempre senza dover riavviare nulla. Se il file non esiste, si limita a non
// fare nulla (l'API continua comunque con il file App_Data corrente).
async function syncCookies(reason) {
  if (cookiesSyncing) return
  let content = null
  let modified = 0
  try {
    content = fs.readFileSync(COOKIES_FILE, "utf8")
    modified = Math.floor(fs.statSync(COOKIES_FILE).mtimeMs)
  } catch {
    cookiesHash = null
    return
  }
  const hash = crypto.createHash("sha1").update(content).digest("hex")
  if (hash === cookiesHash) return

  cookiesSyncing = true
  try {
    const i = preferred
    const res = await fetch(`${API_BASES[i]}/api/download/cookies`, {
      method: "POST",
      headers: {
        "X-API-Key": API_KEY,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ content, modified }),
    })
    const text = await res.text().catch(() => "")
    console.log(`[cookies] sync ${res.status} (${reason}): ${text.slice(0, 120)}`)
    if (res.ok) {
      let parsed = null
      try { parsed = JSON.parse(text) } catch { /* non json */ }
      if (!parsed || !parsed.skipped) cookiesHash = hash
    }
  } catch (e) {
    const reason2 = (e && (e.cause && e.cause.message) || e.message || String(e))
    console.error(`[cookies] sync fallito (${reason}): ${reason2}`)
  } finally {
    cookiesSyncing = false
  }
}

function scheduleCookiesSync() {
  setInterval(() => { syncCookies("cron").catch(() => {}) }, 120000)
}

// Ordine di tentativo per un download: la preferita prima, le altre dopo.
// Serve solo se la preferita muore a metà richiesta.
function baseOrder() {
  return [preferred, ...API_BASES.map((_, i) => i).filter((i) => i !== preferred)]
}

async function proxyDownload(req, res, url) {
  const controller = new AbortController()
  res.on("close", () => {
    if (!res.writableEnded) controller.abort()
  })

  const started = Date.now()
  const search = url.search.startsWith("?") ? url.search.slice(1) : url.search
  const order = baseOrder()

  // autopassa sempre i cookie dalla root del progetto all'API prima del download
  await syncCookies("download").catch(() => {})

  let upstream = null
  let used = null

  for (const i of order) {
    if (controller.signal.aborted) return
    const target = `${API_BASES[i]}/api/download/stream?${search}`
    console.log(`[proxy] richiesta verso ${API_BASES[i]}`)

    const r = await fetch(target, {
      headers: { "X-API-Key": API_KEY },
      signal: controller.signal,
    }).catch((e) => {
      if (controller.signal.aborted) return null
      const reason = (e && (e.cause && e.cause.message) || e.message || String(e))
      const code = (e && e.cause && e.cause.code) || ""
      console.error(`[proxy] ${API_BASES[i]} non raggiungibile: ${reason} ${code}`)
      return false
    })

    if (r === null) return
    if (r === false) continue

    upstream = r
    used = i
    break
  }

  if (!upstream) {
    return sendJson(res, 502, {
      message: "Nessuna base API raggiungibile. Riprova tra qualche secondo.",
    })
  }

  console.log(`[proxy] upstream ${API_BASES[used]} status=${upstream.status} in ${Date.now() - started}ms`)

  if (!upstream.ok) {
    const text = await upstream.text().catch(() => "")
    let message = text
    try { message = JSON.parse(text).message || text } catch { /* non json */ }
    return sendJson(res, upstream.status, { message: message.slice(0, 400) })
  }

  // attachment: il browser salva su disco invece di riprodurre in pagina.
  let disposition = upstream.headers.get("content-disposition") || ""
  if (/^inline/i.test(disposition)) disposition = "attachment" + disposition.slice(6)
  if (!disposition) disposition = 'attachment; filename="download"'

  const headers = {
    "Content-Type": upstream.headers.get("content-type") || "application/octet-stream",
    "Content-Disposition": disposition,
    "Cache-Control": "no-store",
    "X-Proxy": "whatsapp-frontend",
    "X-Api-Base": API_BASES[used],
  }

  res.writeHead(upstream.status, headers)
  if (!upstream.body) {
    console.log("[proxy] upstream.body assente: risposta vuota")
    return res.end()
  }

  let sent = 0
  const counter = new Transform({
    transform(chunk, enc, cb) { sent += chunk.length; cb(null, chunk) },
  })

  await pipeline(Readable.fromWeb(upstream.body), counter, res).catch((e) => {
    controller.abort()
    console.error(`[proxy] stream interrotto dopo ${sent} byte: ${e && e.message}`)
  })

  console.log(`[proxy] completati ${sent} byte in ${Date.now() - started}ms`)
}

async function proxyHealth(req, res, url) {
  const i = preferred
  const upstream = await fetch(`${API_BASES[i]}/api/download/health`, {
    headers: { "X-API-Key": API_KEY },
  }).catch((e) => {
    const reason = (e && (e.cause && e.cause.message) || e.message || String(e))
    console.error(`[health] ${API_BASES[i]} non raggiungibile: ${reason}`)
    return null
  })

  if (!upstream) {
    await probeBases("health fallito")
    return sendJson(res, 502, { ok: false, message: "API non raggiungibile" })
  }

  const body = await upstream.text().catch(() => "")
  let parsed = null
  try { parsed = JSON.parse(body) } catch { /* non json */ }

  sendJson(res, upstream.status, {
    ok: upstream.ok,
    base: API_BASES[i],
    api: parsed || body.slice(0, 300),
  })
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`)

  try {
    if (url.pathname === "/api/download/stream") return await proxyDownload(req, res, url)
    if (url.pathname === "/api/health") return await proxyHealth(req, res, url)
    if (url.pathname === "/api/info") {
      return sendJson(res, 200, {
        ok: true,
        uptimeSec: Math.floor((Date.now() - SERVER_START) / 1000),
        node: process.version,
        port: PORT,
        apiBases: API_BASES,
        activeBase: API_BASES[preferred],
      })
    }
    if (url.pathname.startsWith("/api/")) return sendJson(res, 404, { message: "Endpoint sconosciuto" })
    if (req.method === "GET") return serveStatic(req, res, url.pathname)
    res.writeHead(405)
    res.end("405")
  } catch (e) {
    console.error(`[server] errore su ${url.pathname}: ${e && e.stack || e}`)
    if (!res.headersSent) sendJson(res, 500, { message: String(e && e.message || e) })
    else if (!res.writableEnded) res.end()
  }
})

server.listen(PORT, "0.0.0.0", async () => {
  console.log(`[frontend] avviato su http://0.0.0.0:${PORT}`)
  console.log(`[frontend] basi API: ${API_BASES.join(", ")}`)
  await probeBases("avvio")
  scheduleProbe()
  scheduleCookiesSync()
  syncCookies("avvio").catch(() => {})
})
