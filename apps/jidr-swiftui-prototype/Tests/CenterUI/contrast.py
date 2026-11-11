#!/usr/bin/env python3
"""Regress small, enabled helper text using actual sRGB token values (WCAG)."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[4]
tokens = {t['name']: t['value'] for t in json.loads((root / 'docs/design/tokens.json').read_text())['color']['tokens']}

def resolve(name, theme):
    value = tokens['jidr-color-' + name][theme]
    while value.startswith('{'):
        value = tokens[value[1:-1]][theme]
    return value

def luminance(value):
    rgb = [int(value[i:i+2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= .04045 else ((c + .055) / 1.055) ** 2.4 for c in rgb]
    return sum(c * weight for c, weight in zip(linear, (.2126, .7152, .0722)))

for theme in ('light', 'dark'):
    text = luminance(resolve('text-tertiary', theme))
    for surface in ('base', 'chrome', 'raised', 'overlay', 'control', 'selected', 'sunken'):
        background = luminance(resolve('surface-' + surface, theme))
        lo, hi = sorted((text, background))
        ratio = (hi + .05) / (lo + .05)
        assert ratio >= 4.5, f'{theme} helper text on {surface}: {ratio:.2f}:1 < 4.5:1'
print('Helper text contrast passed: 14 light/dark surface combinations >= 4.5:1')
