#!/usr/bin/env python3
"""Сколько в тексте слов и какой длины предложения. Блоки кода и заголовки не считаются.

    python3 measure-sentences.py docs/articles/self-update.md
"""
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
prose = re.sub(r"```.*?```", "", text, flags=re.S)
prose = re.sub(r"^#.*$", "", prose, flags=re.M)
# Пункт списка читается отдельно, поэтому считается отдельным предложением.
prose = re.sub(r"\n\s*[-*]\s+", ". ", prose)
sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", prose) if len(s.strip()) > 3]
lengths = [len(s.split()) for s in sentences]
average = sum(lengths) / len(lengths) if lengths else 0

print(f"слов: {len(prose.split())}")
print(f"предложений: {len(sentences)}, средняя длина: {average:.1f}")
for sentence in sorted(sentences, key=lambda s: -len(s.split()))[:3]:
    print(f"  длинное ({len(sentence.split())}): {' '.join(sentence.split())[:100]}")
