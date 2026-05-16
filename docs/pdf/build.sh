#!/usr/bin/env bash
# Rebuild markdown-is-the-substrate.pdf from the consolidated source.
# Requires: pandoc 3+, weasyprint.

set -e
cd "$(dirname "$0")"

pandoc manifesto-consolidated.md \
    --pdf-engine=weasyprint \
    --css=./style.css \
    --metadata title="Markdown is the substrate" \
    --metadata subtitle="A manifesto for the live-document runtime" \
    --metadata author="Christian Beaumont, Foundation42" \
    --metadata date="2026-05-16" \
    --standalone \
    -o markdown-is-the-substrate.pdf

echo "Built: $(pwd)/markdown-is-the-substrate.pdf"
