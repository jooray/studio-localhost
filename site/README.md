# Localhost Recording Studio website

A single static page. Plain HTML, CSS and JavaScript: no build step, no CDN, no tracking.
All URLs are relative, so it works at a domain root or under a GitHub Pages sub-path
such as `https://jooray.github.io/studio-localhost/`.

```
site/
  index.html
  assets/
    site.css, site.js
    fonts/      Geist and Geist Mono (woff2, SIL OFL, licence in OFL.txt)
    img/        icon, favicon, screenshots (webp), polar.svg, og.jpg
  media/        filled separately (see below)
```

## Media files

The page checks for these on load with a `HEAD` request and swaps them in when they exist.
Until then it shows a framed placeholder, and while a file is missing it checks again every
20 seconds, so a preview picks up new renders without a reload.

| File | Used for | When missing |
|---|---|---|
| `media/ad.mp4` | the ad video | placeholder "LRS-000 · Ad in production" |
| `media/ad-poster.jpg` | video poster | video shows without a poster |
| `media/ad.vtt` | English captions track | no captions track |
| `media/ad-script.txt` | "Read the voiceover" transcript under the video | transcript hidden |
| `media/run-song.mp3` | the "Run, run, run" player | disabled player with a note |
| `media/run-song.json` | optional song details: `style`, `lyrics`, `model`, `device`, `steps`, `seed`, `render_time` | only the default rows |

## Preview locally

Any static file server works. With Python (nothing to install):

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory site
```

Then open <http://127.0.0.1:8765/>.

Python's built-in server does not support HTTP range requests, so in Chrome, dragging the
song's seek bar may jump back to the start. GitHub Pages supports ranges, so this only
affects the local preview. Opening `index.html` straight from disk (`file://`) also works;
the page then probes media with a hidden audio/video element instead of `HEAD`.

## Publish later

Pick one:

1. **Branch.** Settings > Pages > Deploy from a branch. Put the contents of `site/` at the
   root of a `gh-pages` branch (for example `git subtree push --prefix site origin gh-pages`).
2. **`/docs` folder.** Rename or copy `site/` to `docs/` on `main` and choose
   "main / docs" in Settings > Pages.
3. **Actions workflow.** Keep `site/` where it is and deploy it with the official actions.
   Settings > Pages > Source: GitHub Actions, then add `.github/workflows/pages.yml`:

   ```yaml
   name: Pages
   on:
     push:
       branches: [main]
       paths: ["site/**"]
     workflow_dispatch:
   permissions:
     contents: read
     pages: write
     id-token: write
   concurrency: { group: pages, cancel-in-progress: true }
   jobs:
     deploy:
       runs-on: ubuntu-latest
       environment: { name: github-pages, url: "${{ steps.d.outputs.page_url }}" }
       steps:
         - uses: actions/checkout@v4
         - uses: actions/configure-pages@v5
         - uses: actions/upload-pages-artifact@v3
           with: { path: site }
         - id: d
           uses: actions/deploy-pages@v4
   ```

GitHub Pages needs a public repository on the free plan. The repo is private until v1, so
publishing waits for that (or for a paid plan).

### The video file

GitHub rejects files over 100 MB in a normal push, and Pages sites are meant to stay under
about 1 GB. Keep `ad.mp4` well under 100 MB (H.264, 1080p, a sensible bitrate), or attach it
to a GitHub Release and point the page at the release asset URL by changing `MEDIA.video` at
the top of `assets/site.js`. Release downloads are served as a generic binary through a redirect, so check that it plays in Safari and Chrome before relying on it. Don't use Git LFS for it: Pages does not serve LFS files.
