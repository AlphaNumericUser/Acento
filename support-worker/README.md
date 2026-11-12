# Acento support worker

A tiny Cloudflare Worker that receives messages from Acento's **Help** sheet and forwards them by email through [Resend](https://resend.com). The Resend key and the destination address are Worker secrets, so they never appear in the app or in this repository.

It accepts `POST` JSON (`message`, `email`, `appVersion`, `macOS`, `language`), validates it, and limits each IP to 3 requests per minute.

## Deploy

```sh
cd support-worker
npm install
npx wrangler login
npx wrangler secret put RESEND_API_KEY   # API key from resend.com
npx wrangler secret put SUPPORT_EMAIL    # address that receives the messages
npx wrangler deploy
```

Then set `AppSignature.supportEndpoint` in `Acento/AcentoApp.swift` to the deployed `*.workers.dev` URL.

Without a verified domain, Resend only delivers to the email that owns the Resend account, so create the Resend account with the same address used for `SUPPORT_EMAIL`.
