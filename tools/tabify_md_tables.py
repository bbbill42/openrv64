#!/usr/bin/env python3
"""Tabify (align) GitHub-flavored markdown tables in place.

Pads every table cell so the pipes line up in the source text, and widens the
delimiter row to match. Alignment markers in the delimiter row (`---`, `:---`,
`---:`, `:---:`) are preserved and control how each cell is padded.

Usage:
    python3 scripts/tabify_md_tables.py doc
    python3 scripts/tabify_md_tables.py doc/architecture.md doc/forwarding.md
    python3 scripts/tabify_md_tables.py --check doc

Arguments may be files or directories; directories are scanned for `*.md`.
`--check` reports files that would change and exits nonzero without writing.

Tables inside fenced code blocks are left alone, as is ASCII art that merely
contains pipes: a table is recognized only by a row followed by a delimiter
row. Cell text is never altered, only the surrounding padding.
"""
import argparse
import re
import sys
import unicodedata
from pathlib import Path

SEP_CELL = re.compile(r'^:?-+:?$')
FENCE = re.compile(r'^(\s*)(`{3,}|~{3,})')
MIN_DASHES = 3


def display_width(text):
    """Column width of `text` in a fixed-width font."""
    width = 0
    for ch in text:
        if unicodedata.combining(ch):
            continue
        width += 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1
    return width


def split_cells(line):
    """Split a table row on unescaped pipes, dropping the outer delimiters."""
    cells, buf, i = [], [], 0
    while i < len(line):
        ch = line[i]
        if ch == '\\' and i + 1 < len(line):
            buf.append(line[i:i + 2])
            i += 2
            continue
        if ch == '|':
            cells.append(''.join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    cells.append(''.join(buf))
    if cells and not cells[0].strip():
        cells.pop(0)
    if cells and not cells[-1].strip():
        cells.pop()
    return [c.strip() for c in cells]


def is_row(line):
    return line.strip().startswith('|')


def is_delimiter_row(line):
    if not is_row(line):
        return False
    cells = split_cells(line.strip())
    return bool(cells) and all(SEP_CELL.match(c) for c in cells)


def pad(text, width, align):
    fill = width - display_width(text)
    if fill <= 0:
        return text
    if align == 'right':
        return ' ' * fill + text
    if align == 'center':
        left = fill // 2
        return ' ' * left + text + ' ' * (fill - left)
    return text + ' ' * fill


def render(rows, delimiters, indent):
    """Return the aligned source lines for one table."""
    ncol = max(len(r) for r in rows + [delimiters])
    rows = [r + [''] * (ncol - len(r)) for r in rows]
    delimiters = delimiters + ['-' * MIN_DASHES] * (ncol - len(delimiters))

    aligns = []
    for cell in delimiters:
        left, right = cell.startswith(':'), cell.endswith(':')
        aligns.append('center' if left and right else
                      'right' if right else
                      'left' if left else 'default')

    widths = [max(MIN_DASHES, max(display_width(r[c]) for r in rows))
              for c in range(ncol)]

    def row_line(cells):
        return indent + '| ' + ' | '.join(
            pad(cells[c], widths[c], aligns[c]) for c in range(ncol)) + ' |'

    bar = []
    for c in range(ncol):
        span = widths[c] + 2
        if aligns[c] == 'center':
            bar.append(':' + '-' * (span - 2) + ':')
        elif aligns[c] == 'right':
            bar.append('-' * (span - 1) + ':')
        elif aligns[c] == 'left':
            bar.append(':' + '-' * (span - 1))
        else:
            bar.append('-' * span)

    out = [row_line(rows[0]), indent + '|' + '|'.join(bar) + '|']
    out.extend(row_line(r) for r in rows[1:])
    return out


def tabify(text):
    """Return (new_text, tables_reformatted)."""
    lines = text.split('\n')
    out, fence, changed, i = [], None, 0, 0
    while i < len(lines):
        line = lines[i]
        fence_match = FENCE.match(line)
        if fence is not None:
            out.append(line)
            if (fence_match and fence_match.group(2)[0] == fence[0]
                    and len(fence_match.group(2)) >= len(fence)):
                fence = None
            i += 1
            continue
        if fence_match:
            fence = fence_match.group(2)
            out.append(line)
            i += 1
            continue
        if (is_row(line) and not is_delimiter_row(line)
                and i + 1 < len(lines) and is_delimiter_row(lines[i + 1])):
            indent = line[:len(line) - len(line.lstrip())]
            header = split_cells(line.strip())
            delimiters = split_cells(lines[i + 1].strip())
            body, j = [], i + 2
            while (j < len(lines) and is_row(lines[j])
                   and not is_delimiter_row(lines[j])):
                body.append(split_cells(lines[j].strip()))
                j += 1
            block = render([header] + body, delimiters, indent)
            if block != lines[i:j]:
                changed += 1
            out.extend(block)
            i = j
            continue
        out.append(line)
        i += 1
    return '\n'.join(out), changed


def collect(paths):
    files = []
    for raw in paths:
        path = Path(raw)
        if path.is_dir():
            files.extend(sorted(path.rglob('*.md')))
        else:
            files.append(path)
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('paths', nargs='+',
                        help='markdown files, or directories to scan for *.md')
    parser.add_argument('--check', action='store_true',
                        help='report files needing changes; do not write')
    args = parser.parse_args(argv)

    total, stale = 0, []
    for path in collect(args.paths):
        source = path.read_text(encoding='utf-8')
        new, count = tabify(source)
        if new == source:
            continue
        stale.append(path)
        total += count
        if args.check:
            print(f'{path}: {count} table(s) not tabified')
        else:
            path.write_text(new, encoding='utf-8')
            print(f'{path}: {count} table(s) reformatted')

    if args.check:
        print(f'{len(stale)} file(s) need tabifying' if stale
              else 'all tables already tabified')
        return 1 if stale else 0
    print(f'total tables reformatted: {total}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
