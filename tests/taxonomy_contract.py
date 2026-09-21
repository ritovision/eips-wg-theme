#!/usr/bin/env python3
"""Differential Zola contract/benchmark for the actual candidate templates.

Usage: python3 tests/taxonomy_contract.py --evidence /tmp/new-evidence
Optional --variant NAME=/path/to/theme can compare independent/combined patches.
--full-prepared accepts an already preprocessed full site; it is copied, never
modified. Only category ordering and XML formatting whitespace are ignored.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path

BASE = 'e5f4b13b584c8b4befdabcfc312a659faa437b7a'
THEME = Path(__file__).resolve().parents[1]
ATOM = '{http://www.w3.org/2005/Atom}'


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')


def canonical_xml(data: bytes):
    def node(element):
        children = [node(child) for child in element if child.tag != ATOM + 'category']
        categories = sorted([node(child) for child in element if child.tag == ATOM + 'category'], key=repr)
        # Keep significant text verbatim, including the escaped HTML body.
        text = element.text if element.text and element.text.strip() else ''
        tail = element.tail if element.tail and element.tail.strip() else ''
        return element.tag, tuple(sorted(element.attrib.items())), text, tuple(children), tuple(categories), tail
    return node(ET.fromstring(data.strip()))


def compare(original: Path, candidate: Path) -> dict:
    left = {str(p.relative_to(original)): p for p in original.rglob('*') if p.is_file()}
    right = {str(p.relative_to(candidate)): p for p in candidate.rglob('*') if p.is_file()}
    assert left.keys() == right.keys(), (left.keys() - right.keys(), right.keys() - left.keys())
    changed = []
    for name, path in left.items():
        a, b = path.read_bytes(), right[name].read_bytes()
        if a == b:
            continue
        assert name.endswith('atom.xml'), f'Non-feed output changed: {name}'
        assert canonical_xml(a) == canonical_xml(b), f'Feed content/structure changed: {name}'
        changed.append(name)
    return {'files': len(left), 'byte_identical': len(left) - len(changed), 'equivalent_feeds': changed}


def build(site: Path, output: Path, log: Path, config: Path | None = None, base_url: str | None = None) -> float:
    args = ['zola'] + (['-c', str(config)] if config else []) + ['build', '--drafts', '-o', str(output)]
    if base_url:
        args.extend(['-u', base_url])
    start = time.monotonic()
    with log.open('w') as stream:
        result = subprocess.run(['/usr/bin/time', '-v', *args], cwd=site, stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'Zola failed ({result.returncode}): {log}\n{log.read_text()}')
    return round(time.monotonic() - start, 3)


def make_mini(site: Path, templates: Path, scenario: str) -> None:
    kinds = ['status', 'category', 'type']
    default_language = 'fr' if scenario == 'multilingual' else 'en'
    if scenario == 'unicode-kind':
        kinds[0] = 'État'
    terms = ['Été Brisé' if scenario == 'safe-slugs' else ('R&D / café' if scenario == 'unicode-kind' else 'Draft'), 'Core', 'Standards Track']
    taxonomies = ', '.join('{name=' + json.dumps(k) + ',feed=true}' for k in kinds)
    if scenario == 'unused-kind':
        taxonomies += ', {name="unused",feed=true}'
    config = f'base_url="https://example.test/nested/site/"\ntitle="Contract"\ndescription="Contract"\ndefault_language="{default_language}"\ngenerate_feeds=true\ntaxonomies=[{taxonomies}]\n'
    if scenario == 'safe-slugs':
        config += '[slugify]\ntaxonomies="safe"\n'
    if scenario == 'multilingual':
        config += f'[languages.en]\ngenerate_feeds=true\ntaxonomies=[{taxonomies}]\n'
    config += '[extra]\n'
    if scenario != 'fallback-banner':
        config += 'banner_taxonomies=[{name=' + json.dumps(kinds[0]) + ',label="All"}]\n'
    write(site / 'zola.toml', config)
    for name in ['base.html', 'atom.xml', 'macros.html']:
        write(site / 'templates' / name, (templates / name).read_text())
    write(site / 'templates/index.html', '{% extends "base.html" %}{% block content %}Home{% endblock %}')
    write(site / 'templates/page.html', '{% extends "base.html" %}{% block content %}{{ page.content | safe }}{% endblock %}')
    write(site / 'templates/taxonomy_list.html', '{% extends "base.html" %}{% block content %}{{ taxonomy.name }}{% endblock %}')
    write(site / 'templates/taxonomy_single.html', '{% extends "base.html" %}{% block content %}{{ term.name }}{% endblock %}')
    languages = ['', '.en'] if scenario == 'multilingual' else ['']
    for suffix in languages:
        write(site / f'content/_index{suffix}.md', '+++\ntitle="Home"\n+++\nHome\n')
        for i in range(1, 5):
            fields = '\n'.join(json.dumps(k) + '=' + json.dumps([t], ensure_ascii=False) for k, t in zip(kinds, terms))
            write(site / f'content/page-{i}{suffix}.md', f'+++\ntitle="Proposal {i}"\ndate=2026-09-{10+i}\ntemplate="page.html"\n[taxonomies]\n{fields}\n[extra]\nnumber={i}\n+++\n# Body\n\nSignificant text **{i}**.\n')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--baseline-ref', default=BASE)
    parser.add_argument('--variant', action='append', default=[])
    parser.add_argument('--full-prepared', type=Path)
    parser.add_argument('--skip-mini', action='store_true')
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=False)
    baseline = args.evidence / 'baseline-templates'
    for name in ['base.html', 'atom.xml', 'macros.html']:
        data = subprocess.check_output(['git', '-C', str(THEME), 'show', f'{args.baseline_ref}:templates/{name}'])
        baseline.mkdir(exist_ok=True)
        (baseline / name).write_bytes(data)
    variants = [('baseline', baseline)]
    if args.variant:
        for raw in args.variant:
            name, path = raw.split('=', 1)
            if not name or '/' in name or name in ('.', '..', 'baseline'):
                raise ValueError(f'Invalid variant: {name}')
            variants.append((name, Path(path).resolve() / 'templates'))
    else:
        variants.append(('candidate', THEME / 'templates'))
    results = {'zola': subprocess.check_output(['zola', '--version'], text=True).strip(), 'mini': {}, 'full': {}}
    def save():
        (args.evidence / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    if not args.skip_mini:
        for scenario in ['ordinary', 'fallback-banner', 'unused-kind', 'unicode-kind', 'safe-slugs', 'multilingual']:
            output = {}
            for name, templates in variants:
                site = args.evidence / scenario / name
                make_mini(site, templates, scenario)
                output[name] = site / 'public'
                seconds = build(site, output[name], site / 'build.log')
                results['mini'][scenario + '/' + name] = {'seconds': seconds}
                if name != 'baseline':
                    results['mini'][scenario + '/' + name].update(compare(output['baseline'], output[name]))
                save()
            print('PASS', scenario, flush=True)
    if args.full_prepared:
        outputs = {}
        original_content = {str(p.relative_to(args.full_prepared)): hashlib.sha256(p.read_bytes()).hexdigest()
                            for p in (args.full_prepared / 'content').rglob('*') if p.is_file()}
        for name, templates in variants:
            site = args.evidence / 'full' / name / 'repo'
            shutil.copytree(args.full_prepared, site, ignore=shutil.ignore_patterns('.git'))
            for template in ['base.html', 'atom.xml']:
                shutil.copyfile(templates / template, site / 'themes/eips-theme/templates' / template)
            content = {str(p.relative_to(site)): hashlib.sha256(p.read_bytes()).hexdigest()
                       for p in (site / 'content').rglob('*') if p.is_file()}
            assert content == original_content, 'Full prepared source changed'
            outputs[name] = site.parent / 'output'
            seconds = build(site, outputs[name], site.parent / 'timing.log', site / 'themes/eips-theme/config/zola.toml', 'http://127.0.0.1:1111/')
            results['full'][name] = {'seconds': seconds, 'content_files': len(content)}
            if name != 'baseline':
                results['full'][name].update(compare(outputs['baseline'], outputs[name]))
            save()
            print('PASS full', name, results['full'][name], flush=True)
    save()

if __name__ == '__main__':
    main()
