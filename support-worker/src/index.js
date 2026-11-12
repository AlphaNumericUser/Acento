// Receives feedback from the Acento app and forwards it by email through Resend.
// The Resend key and destination address live only in Worker secrets, never in the app.

const MAX_BODY_BYTES = 12_000;
const MAX_MESSAGE = 5_000;
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export default {
  async fetch(request, env) {
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (env.LIMITER) {
      const { success } = await env.LIMITER.limit({ key: ip });
      if (!success) return json({ error: "rate_limited" }, 429);
    }

    const raw = await request.text();
    if (raw.length > MAX_BODY_BYTES) return json({ error: "too_large" }, 413);

    let payload;
    try {
      payload = JSON.parse(raw);
    } catch {
      return json({ error: "invalid_json" }, 400);
    }

    const message = clean(payload.message, MAX_MESSAGE);
    const email = clean(payload.email, 254);
    const appVersion = clean(payload.appVersion, 40) || "unknown";
    const macOS = clean(payload.macOS, 40) || "unknown";
    const language = clean(payload.language, 20) || "unknown";

    if (message.length < 3) return json({ error: "empty_message" }, 400);
    if (!EMAIL_PATTERN.test(email)) return json({ error: "invalid_email" }, 400);
    if (!env.RESEND_API_KEY || !env.SUPPORT_EMAIL) return json({ error: "not_configured" }, 500);

    const text = [
      message,
      "",
      "—",
      `Reply to: ${email}`,
      `Acento: ${appVersion}`,
      `macOS: ${macOS}`,
      `Language: ${language}`,
    ].join("\n");

    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "Acento Support <onboarding@resend.dev>",
        to: [env.SUPPORT_EMAIL],
        subject: `Acento feedback · ${appVersion}`,
        text,
        reply_to: email,
      }),
    });

    if (!response.ok) {
      console.error("Resend failed", response.status, await response.text());
      return json({ error: "delivery_failed" }, 502);
    }
    return json({ ok: true }, 200);
  },
};

function clean(value, limit) {
  return typeof value === "string" ? value.trim().slice(0, limit) : "";
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
