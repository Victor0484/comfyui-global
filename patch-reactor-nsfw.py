#!/usr/bin/env python3
"""Disable only ReActor's image moderation check in this custom Docker build.

Patch the cloned source at build time so all fresh Pods have consistent behavior.
Fail if upstream ReActor changes the expected detector interface.
"""

import ast
from pathlib import Path

REACTOR = Path('/opt/comfyui-baked/custom_nodes/ComfyUI-ReActor')
SOURCE = REACTOR / 'scripts' / 'reactor_sfw.py'
NODES = REACTOR / 'nodes.py'

if not SOURCE.is_file() or not NODES.is_file():
    raise SystemExit('ERROR: ReActor detector module or nodes.py not found; refusing to build')

nodes_source = NODES.read_text(encoding='utf-8')
if 'sfw.nsfw_image(' not in nodes_source:
    raise SystemExit('ERROR: ReActor no longer invokes sfw.nsfw_image; review upstream before disabling filter')

source = SOURCE.read_text(encoding='utf-8')
syntax_tree = ast.parse(source, filename=str(SOURCE))
functions = [n for n in syntax_tree.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == 'nsfw_image']
if len(functions) != 1:
    raise SystemExit('ERROR: Could not identify a unique nsfw_image function; review upstream')

fn = functions[0]
first_stmt = fn.body[0]
if first_stmt.lineno <= fn.lineno:
    raise SystemExit('ERROR: Unexpected one-line nsfw_image implementation')

lines = source.splitlines(keepends=True)
indent = ' ' * first_stmt.col_offset
replacement = [
    f'{indent}"""ReActor content classification is disabled in this private image."""\n',
    f'{indent}return False\n',
]
patched_lines = lines[:first_stmt.lineno - 1] + replacement + lines[fn.end_lineno:]
patched = ''.join(patched_lines)
ast.parse(patched, filename=str(SOURCE))
compile(patched, str(SOURCE), 'exec')
SOURCE.write_text(patched, encoding='utf-8')
print('ReActor NSFW classification disabled; other ReActor features unchanged.')
