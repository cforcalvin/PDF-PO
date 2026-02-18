# PDF-PO

PDF-PO is a simple, open-source macOS PDF editor written in Swift. It lets you open a PDF, select text, and replace the selection by masking it and drawing new text on top.

## Features
- Open and view PDFs
- Select text and replace it (via annotations)
- Save a new PDF copy

## Requirements
- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)

## Run locally
```bash
swift run
```

## Build an app bundle
```bash
chmod +x scripts/build_app.sh
./scripts/build_app.sh
```

The app bundle will be created at `build/PDFPO.app`.

## Build a DMG
```bash
chmod +x scripts/build_dmg.sh
./scripts/build_dmg.sh
```

The DMG will be created at `build/PDFPO.dmg`.

## GitHub Pages
This repo includes a `docs/` folder with a simple landing page. Enable GitHub Pages in the repository settings and point it to the `docs/` folder on the default branch.

## Notes on text editing
PDFPO replaces selected text by covering the original glyphs with a white rectangle and adding a FreeText annotation. This changes the visible text but does not rewrite the original PDF content stream.

## License
MIT. See `LICENSE`.
