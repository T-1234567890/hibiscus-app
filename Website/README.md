# Hibiscus website

This directory contains the static Hibiscus project website. It has no build step or runtime dependencies.

Preview it locally from the repository root:

```sh
cd Website
python3 -m http.server 8000
```

Then open <http://localhost:8000/>.

Download buttons link to the App Store. Update `downloadLabel`, `downloadHoverLabel`, and `downloadURL` in `site-config.js` to change their shared presentation and destination; keep the HTML fallback links and labels in sync.

The App Store screenshots in `assets/screenshots/` are the supplied final marketing artwork. The first page from the source set is intentionally omitted.
