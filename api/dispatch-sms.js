import { createClient } from '@supabase/supabase-js'

const BULKSMSBD_API_URL = 'http://bulksmsbd.net/api/smsapimany'

function normalizeNumber(num) {
  if (!num) return ''
  let n = String(num).replace(/[^0-9+]/g, '')
  if (n.startsWith('+')) n = n.slice(1)
  if (n.startsWith('880')) return n
  if (n.startsWith('0')) return '880' + n.slice(1)
  return n
}

export default async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'POST') {
    res.setHeader('Allow', 'GET, POST')
    return res.status(405).json({ error: 'Method Not Allowed' })
  }

  const apiKey = process.env.BULKSMSBD_API_KEY
  const senderId = process.env.BULKSMSBD_SENDER_ID
  const supabaseUrl = process.env.VITE_SUPABASE_URL
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY

  if (!apiKey || !senderId || !supabaseUrl || !serviceKey) {
    return res.status(500).json({
      error: 'bulkSMSBD dispatch is not configured (missing environment variables)',
      missing: {
        BULKSMSBD_API_KEY: !apiKey,
        BULKSMSBD_SENDER_ID: !senderId,
        VITE_SUPABASE_URL: !supabaseUrl,
        SUPABASE_SERVICE_ROLE_KEY: !serviceKey,
      },
    })
  }

  const supabase = createClient(supabaseUrl, serviceKey)

  const { data: sms, error: smsErr } = await supabase
    .from('messages')
    .select('*')
    .eq('channel', 'sms')
    .eq('status', 'queued')
    .lte('scheduled_at', new Date().toISOString())
    .order('created_at', { ascending: true })
    .limit(500)

  if (smsErr) {
    return res.status(500).json({ error: smsErr.message })
  }

  const { data: others, error: othersErr } = await supabase
    .from('messages')
    .select('id')
    .neq('channel', 'sms')
    .eq('status', 'queued')
    .lte('scheduled_at', new Date().toISOString())

  let simulatedCount = 0
  if (!othersErr && others?.length) {
    simulatedCount = others.length
    const { error: simErr } = await supabase
      .from('messages')
      .update({ status: 'sent', sent_at: new Date().toISOString() })
      .in(
        'id',
        others.map((m) => m.id),
      )
    if (simErr) {
      return res.status(500).json({ error: simErr.message })
    }
  }

  if (!sms || sms.length === 0) {
    return res.json({ dispatched: 0, sms: 0, simulated: simulatedCount })
  }

  const messages = sms.map((m) => ({
    to: normalizeNumber(m.recipient_ref),
    message: m.body,
  }))

  const payload = {
    api_key: apiKey,
    senderid: senderId,
    messages: messages,
  }

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)

  let resp
  try {
    resp = await fetch(BULKSMSBD_API_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: controller.signal,
    })
  } catch (e) {
    clearTimeout(timer)
    return res.status(502).json({
      error: 'bulkSMSBD request failed',
      detail: e.message,
    })
  }
  clearTimeout(timer)

  let result
  try {
    result = await resp.json()
  } catch {
    result = {}
  }

  const code = result?.response_code ?? result?.code ?? result?.status
  const ok = code === 202

  const { error: updErr } = await supabase
    .from('messages')
    .update({
      status: ok ? 'sent' : 'failed',
      sent_at: ok ? new Date().toISOString() : null,
      error: ok
        ? null
        : `bulkSMSBD ${code}: ${result?.response_message ?? result?.message ?? 'unknown error'}`,
    })
    .in(
      'id',
      sms.map((m) => m.id),
    )

  if (updErr) {
    return res.status(500).json({ error: updErr.message })
  }

  return res.json({
    dispatched: sms.length,
    sms: sms.length,
    simulated: simulatedCount,
    response_code: code,
    ok,
  })
}
