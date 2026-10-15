# Website

Static marketing site for the app: a landing page, a privacy policy and a support page.
Plain HTML and CSS, no framework, no build step. What is in this folder is what gets served.

## Structure

```
site/
├── index.html            Landing page
├── privacy/index.html    Privacy policy (served at /privacy/)
├── support/index.html    Support and FAQ (served at /support/)
├── 404.html              Served for any unknown path, with HTTP 404
├── styles.css            All styles
├── img/                  App screenshots as WebP (two widths each, used via srcset)
├── favicon.svg, apple-touch-icon.png
├── robots.txt, sitemap.xml
└── .assetsignore         Files that are never uploaded (this README)
```

Absolute URLs (canonical, Open Graph, `sitemap.xml`, `robots.txt`) point to the production domain.
If you host your own copy, search and replace that domain.

## Preview locally

Any static file server works, for example:

```bash
cd site && python3 -m http.server 8080
# open http://localhost:8080
```

Or with the same runtime used in production (also serves `404.html` the same way):

```bash
npx wrangler dev
```

## Deploy (Cloudflare Workers static assets)

The repository root has a `wrangler.jsonc` that serves `./site` as static assets:

- `assets.directory`: `./site`
- `html_handling: auto-trailing-slash`: `/privacy` redirects to `/privacy/`
- `not_found_handling: 404-page`: unknown paths return `404.html` with status 404
- `routes`: the custom domain the Worker is attached to

Prerequisites: Node.js 18+ and a Cloudflare account.

```bash
npx wrangler login     # once, opens the browser
npx wrangler deploy    # from the repository root
```

To deploy to your own account, change `name` and `routes` in `wrangler.jsonc`
(or remove `routes` and set `"workers_dev": true` to use a `*.workers.dev` URL).
Nothing here is tied to Cloudflare: you can upload the `site/` folder to any static host
(GitHub Pages, Netlify, S3, nginx…). Just keep `/privacy/` and `/support/` reachable.

## Verify after a deploy

```bash
for p in / /privacy/ /support/ /does-not-exist; do
  printf '%s ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' "https://YOUR-DOMAIN$p"
done
# expected: 200, 200, 200, 404
```

The privacy and support URLs are linked from the App Store listing, so they must always return 200.
