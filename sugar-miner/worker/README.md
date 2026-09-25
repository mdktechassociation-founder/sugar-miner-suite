# SugarBridge — deploy in 5 minutes

A WebSocket ⇄ TCP bridge so a browser page can talk to **PooLab's raw Stratum port**.

```
browser (SUGAR_MINER_SINGLE_FILE.html)
      │  wss://
      ▼
Cloudflare Worker  ──connect()──►  stratum.poolab.org:8451   (yespowerSUGAR)
```

## Deploy

```bash
npm install -g wrangler
wrangler login                     # opens the browser, one time
cd sugar-worker
wrangler deploy                    # prints https://sugar-bridge.<you>.workers.dev
```

Optional but recommended — lock it to your own page so strangers can't use your
Worker as a free open relay (Workers dashboard → your worker → Settings → Variables):

| Variable | Example | Meaning |
|---|---|---|
| `ALLOWED_ORIGINS` | `https://mysite.example` or `*` | comma-separated allow-list checked against the `Origin` header |
| `POOL_HOST` | `stratum.poolab.org` | pool to relay to |
| `POOL_PORT` | `8451` | pool port |

## Point the HTML miner at it

Open `SUGAR_MINER_SINGLE_FILE.html` and either

* edit the **WebSocket proxy (stratum)** field to
  `wss://sugar-bridge.<you>.workers.dev`, or
* append `?ws=` to the page URL:
  `SUGAR_MINER_SINGLE_FILE.html?ws=wss://sugar-bridge.<you>.workers.dev`

**Before you press Connect & mine:** replace the payout address — the file ships
with someone else's wallet in that box.

## Notes / limits

* `connect()` is a Workers runtime API, no build flags needed. Outbound TCP to
  Cloudflare IPs, `localhost` and private ranges is blocked; port 25 is blocked.
  `stratum.poolab.org:8451` is fine.
* Each open TCP socket counts toward the Workers limit on simultaneous open
  connections (1 per miner here, so no issue).
* Cloudflare bills **wall-clock duration** for a WebSocket passthrough on the
  paid (Unbound) plan — an always-on miner holds the connection open, so keep an
  eye on usage. On the free plan the connection lives while CPU budget allows;
  this worker barely uses CPU because it never parses the JSON, it just relays.
* Long connections *will* occasionally drop (edge maintenance, plan limits). The
  HTML miner already reconnects with exponential backoff and keeps mining the
  last job meanwhile, so a blip is harmless.
* Anyone who learns the URL can mine through it unless you set `ALLOWED_ORIGINS`.
  Note that a non-browser client can forge `Origin`, so treat it as a speed bump,
  not authentication. For real locking, add a secret path or token check.
