"use strict"

const http = require("http")
const path = require("path")
const fs = require("fs")

const PORT = Number(process.env.PORT) || 8080
const PUBLIC_DIR = path.join(__dirname, "public")

// Render non raggiunge il Pi: la risoluzione passa dall'API IIS
// (82.223.13.114) che a sua volta interroga Cobalt sul Pi.
// Il download finale è un 302 verso il tunnel HTTPS di Cobalt:
// il browser scarica diretto dal Pi, Render non proxy i byte.
const API_BASES = (process.env.API_BASES
  ? process.env.API_BASES.split(",")
  : ["http://82.223.13.114"]
).map((s) => s.trim()).filter(Boolean)

const API_KEY = "WaDl-2026-9F2C8E4B1A7D6F03C5B9E2A48D1F7A92"

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

// Mappa i parametri della richiesta all'endpoint POST dell'API IIS.
function resolveEndpoint(search) {
  const p = new URLSearchParams(search)
  const url = (p.get("url") || "").toLowerCase()
  const query = p.get("query") || ""
  const audio = p.get("audio") === "true"
  if (url.includes("tiktok.com")) return { endpoint: "tiktok", url: p.get("url") || "", query }
  if (url.includes("instagram.com")) return { endpoint: "instagram", url: p.get("url") || "", query }
  if (url.includes("facebook.com") || url.includes("fb.watch")) return { endpoint: "facebook", url: p.get("url") || "", query }
  if (audio) return { endpoint: "song", url: p.get("url") || "", query }
  let vurl = p.get("url") || ""
  let vquery = query
  if (!vurl && vquery) { vurl = `ytsearch1:${vquery}`; vquery = "" }
  return { endpoint: "youtube", url: vurl, query: vquery }
}

// POST /api/download/{endpoint} sull'API IIS → URL file (tunnel Cobalt).
async function resolveMediaUrl(base, info, signal) {
  const r = await fetch(`${base}/api/download/${info.endpoint}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-API-Key": API_KEY },
    body: JSON.stringify({ url: info.url, query: info.query }),
    signal: signal || AbortSignal.timeout(120000),
  })
  const data = await r.json().catch(() => ({}))
  if (!r.ok || data.ok !== true) {
    throw new Error(data.error || data.message || `API ${r.status}`)
  }
  const media = Array.isArray(data.media) ? data.media : []
  if (!media.length) throw new Error("Nessun file multimediale trovato")
  const m = media[0]
  const title = (data.title || "download").toString()
  const ext = (m.ext || "mp4").toString()
  return { url: m.url, filename: `${title}.${ext}` }
}

async function handleStream(req, res, url) {
  const controller = new AbortController()
  res.on("close", () => { if (!res.writableEnded) controller.abort() })

  const search = url.search.startsWith("?") ? url.search.slice(1) : url.search
  const info = resolveEndpoint(search)

  try {
    let media = null
    let lastErr = null
    for (const base of API_BASES) {
      if (controller.signal.aborted) return
      try {
        media = await resolveMediaUrl(base, info, controller.signal)
        break
      } catch (e) {
        lastErr = e
        console.error(`[stream] ${base} fallito: ${e && e.message}`)
      }
    }
    if (!media) throw lastErr || new Error("Nessuna base API raggiungibile")
    if (!media.url) throw new Error("URL del file mancante")

    const safeName = String(media.filename || "download")
      .replace(/[\\/:*?"<>|]/g, "_").slice(0, 120) || "download"

    res.writeHead(302, {
      "Location": media.url,
      "Content-Disposition": `attachment; filename="${safeName}"`,
      "Cache-Control": "no-store",
      "X-Proxy": "whatsapp-frontend",
    })
    res.end()
  } catch (e) {
    if (controller.signal.aborted) return
    sendJson(res, 502, { message: String(e && e.message || e) })
  }
}

async function handleHealth(req, res) {
  for (const base of API_BASES) {
    try {
      const r = await fetch(`${base}/api/download/health`, {
        headers: { "X-API-Key": API_KEY },
        signal: AbortSignal.timeout(15000),
      })
      const body = await r.text().catch(() => "")
      let parsed = null
      try { parsed = JSON.parse(body) } catch { /* non json */ }
      if (r.ok) {
        return sendJson(res, 200, { ok: true, base, api: parsed || body.slice(0, 300) })
      }
    } catch (e) {
      console.error(`[health] ${base} non raggiungibile: ${e && e.message}`)
    }
  }
  sendJson(res, 502, { ok: false, message: "API non raggiungibile" })
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`)

  try {
    if (url.pathname === "/api/download/stream") return await handleStream(req, res, url)
    if (url.pathname === "/api/health") return await handleHealth(req, res)
    if (url.pathname === "/api/info") {
      return sendJson(res, 200, {
        ok: true,
        uptimeSec: Math.floor((Date.now() - SERVER_START) / 1000),
        node: process.version,
        port: PORT,
        apiBases: API_BASES,
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

server.listen(PORT, "0.0.0.0", () => {
  console.log(`[frontend] avviato su http://0.0.0.0:${PORT}`)
  console.log(`[frontend] basi API: ${API_BASES.join(", ")}`)
})
