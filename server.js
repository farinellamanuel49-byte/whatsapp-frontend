"use strict"

const http = require("http")
const path = require("path")
const fs = require("fs")

const PORT = Number(process.env.PORT) || 8080
const PUBLIC_DIR = path.join(__dirname, "public")

// Cobalt self-hosted sul Pi: unico backend, niente IIS.
const COBALT_BASE = (process.env.COBALT_URL || "http://5.134.123.152:9000").replace(/\/+$/, "")
const COBALT_KEY = process.env.COBALT_API_KEY ||
  "290f64f0a911460ea83fcd9668d2e93a0ab67030e44742998f42c69bbfac614e"

const YT_SEARCH_URL = "https://www.youtube.com/youtubei/v1/search"
const YT_API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

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

// ---------- YouTube search (InnerTube pubblico) ----------

async function youtubeSearch(query) {
  try {
    const payload = {
      context: { client: { clientName: "WEB", clientVersion: "2.20241101.01.00", hl: "it", gl: "IT" } },
      query,
    }
    const r = await fetch(`${YT_SEARCH_URL}?key=${YT_API_KEY}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(20000),
    })
    const json = await r.json()
    return findVideoId(json)
  } catch {
    return null
  }
}

function findVideoId(node) {
  if (node && typeof node === "object") {
    if (!Array.isArray(node) && typeof node.videoId === "string" && node.videoId.length === 11) {
      return node.videoId
    }
    for (const v of Object.values(node)) {
      const f = findVideoId(v)
      if (f) return f
    }
  } else if (Array.isArray(node)) {
    for (const v of node) {
      const f = findVideoId(v)
      if (f) return f
    }
  }
  return null
}

// ---------- Cobalt ----------

function isYoutubeUrl(u) {
  const s = (u || "").toLowerCase()
  return s.includes("youtube.com") || s.includes("youtu.be") || s.includes("ytsearch") || s.includes("music.youtube.com")
}

// Risolve un URL (o query YouTube) in un URL file diretto via Cobalt.
// Ritorna { url, filename } oppure lancia Error con messaggio leggibile.
async function cobaltResolve({ url, query, audio, quality }, signal) {
  let target = (url || "").trim()

  // YouTube: se è una ricerca o non è un URL diretto, trova il videoId.
  if (isYoutubeUrl(target) || !target || target.startsWith("ytsearch")) {
    if (target.startsWith("ytsearch")) {
      const i = target.indexOf(":")
      target = i >= 0 ? target.slice(i + 1) : target.replace(/^ytsearch\d*/, "")
    }
    if (!isYoutubeUrl(target) || target.includes("ytsearch")) {
      const term = target && !target.startsWith("http") ? target : (query || "")
      if (!term) throw new Error("Inserisci un titolo o un link.")
      const id = await youtubeSearch(term)
      if (!id) throw new Error(`Nessun video YouTube trovato per "${term}"`)
      target = `https://youtu.be/${id}`
    }
    target = target.replace("music.youtube.com", "www.youtube.com")
  } else if (!target && query) {
    target = query
  }
  if (!target) throw new Error("URL mancante.")

  const body = { url: target }
  if (audio) {
    body.downloadMode = "audio"
    body.audioFormat = "mp3"
    body.audioBitrate = "320"
  } else {
    body.downloadMode = "auto"
    body.videoQuality = quality && quality !== "0" ? String(quality) : "720"
  }

  const r = await fetch(`${COBALT_BASE}/`, {
    method: "POST",
    headers: {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Authorization": `Api-Key ${COBALT_KEY}`,
    },
    body: JSON.stringify(body),
    signal: signal || AbortSignal.timeout(120000),
  })
  const data = await r.json().catch(() => ({}))

  const status = data.status || ""
  if (status === "error") {
    const code = data.error && (data.error.code || data.error)
    throw new Error(`Cobalt: ${code || "errore"}`)
  }
  if (status === "picker") {
    throw new Error("Cobalt: video con più formati, scelta non supportata")
  }
  if ((status === "tunnel" || status === "redirect" || status === "local-processing") && data.url) {
    // local-processing restituisce tunnel[] invece di url: preso il primo
    const fileUrl = data.url || (Array.isArray(data.tunnel) && data.tunnel[0])
    if (fileUrl) {
      return { url: fileUrl, filename: data.filename || data.output && data.output.filename || "download" }
    }
  }
  if (status === "local-processing" && Array.isArray(data.tunnel) && data.tunnel.length) {
    return { url: data.tunnel[0], filename: (data.output && data.output.filename) || "download" }
  }
  throw new Error(`Cobalt: risposta non valida (${status || "sconosciuto"})`)
}

// ---------- endpoint ----------

async function handleStream(req, res, url) {
  const controller = new AbortController()
  res.on("close", () => { if (!res.writableEnded) controller.abort() })

  const p = url.searchParams
  const audio = p.get("audio") === "true"
  const quality = p.get("quality") || "0"

  try {
    const media = await cobaltResolve(
      { url: p.get("url") || "", query: p.get("query") || "", audio, quality },
      controller.signal,
    )
    if (!media.url) throw new Error("URL del file mancante")

    const safeName = String(media.filename || "download")
      .replace(/[\\/:*?"<>|]/g, "_").slice(0, 120) || "download"

    // 302: il browser scarica direttamente dal tunnel Cobalt (Pi),
    // Render non proxy più i byte.
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
  try {
    const r = await fetch(`${COBALT_BASE}/`, {
      signal: AbortSignal.timeout(8000),
      redirect: "manual",
    })
    sendJson(res, 200, { ok: r.status < 500, cobalt: COBALT_BASE, cobaltStatus: r.status })
  } catch (e) {
    sendJson(res, 502, { ok: false, message: "Cobalt non raggiungibile", cobalt: COBALT_BASE })
  }
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
        cobalt: COBALT_BASE,
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
  console.log(`[frontend] cobalt: ${COBALT_BASE}`)
})
