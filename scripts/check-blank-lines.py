#!/usr/bin/env python3
"""Checks the blank lines that separate the groups of statements in MoonBit and Python bodies.

Usage: check-blank-lines.py [--fix] [FILE...]
Without FILE it checks every tracked .mbt file and every tracked Python file under test/.

Enforced rules:
  flow-boundary  A multi-line if, match, for, while, loop, try, with, closure or local function is separated by a
                 blank line from the statements before and after it. A defer or errdefer line is never separated.
  assert-group   A run of asserts in a test is separated by a blank line from the statement before it.
"""

import ast
import re
import subprocess
import sys
from pathlib import Path

FLOW_MESSAGE = "flow-boundary: separate the multi-line statement from its neighbours with a blank line"
ASSERT_MESSAGE = "assert-group: separate the asserts from the statement before them"

MBT_FLOW = re.compile(
    r"^(?:let\s+(?:mut\s+)?[^=]+?=\s*|[\w.]+\s*=\s*|return\s+)?(?:if|match|for|while|loop|try)\b|^(?:async\s+)?fn\b"
)
MBT_CLOSURE_END = re.compile(r"=>\s*\{$")
MBT_ASSERT = re.compile(r"^(?:@\w+\.)?(?:assert_\w+|assert|inspect)\(")
MBT_DEFER = re.compile(r"^(?:err)?defer\b")
MBT_CONTINUED = ("+", "-", "*", "/", "%", "&&", "||", "=", "->", "|>", ",")
MBT_CONTINUING_START = ("else", "catch", "is ", "as ", ".", "|>", "&&", "||")
MBT_LET = re.compile(r"^let\s+(?:mut\s+)?([^=]+?)\s*=")
MBT_HEAD_PREFIX = re.compile(r"^(?:let\s+(?:mut\s+)?[^=]+?=\s*|[\w.]+\s*=\s*|return\s+)")
MBT_TEST = re.compile(r"^(?:async\s+)?test\b")
MBT_MATCH = re.compile(r"(?:^|[^\w.])match\b")
MBT_OTHER_PREFIX = re.compile(r"(?:\breturn|[=(\[,:|])$")


def skip_string(line, start):
    index = start + 1
    while index < len(line):
        char = line[index]
        if char == "\\":
            if line.startswith("\\{", index):
                depth = 1
                index += 2
                while index < len(line) and depth > 0:
                    if line[index] == "{":
                        depth += 1
                    elif line[index] == "}":
                        depth -= 1
                    elif line[index] == '"':
                        index = skip_string(line, index) - 1
                    index += 1
                continue
            index += 2
            continue
        if char == '"':
            return index + 1
        index += 1
    return len(line)


def mask_mbt_line(line):
    """Blanks the strings and the comment so only code is left."""
    stripped = line.lstrip()
    if stripped.startswith(("#|", "$|")):
        return ""
    out = []
    index = 0
    while index < len(line):
        char = line[index]
        if line.startswith("//", index):
            break
        if char == '"':
            end = skip_string(line, index)
            out.append('"' + " " * max(end - index - 2, 0) + '"')
            index = end
            continue
        if char == "'":
            if line.startswith("\\", index + 1):
                end = line.find("'", index + 3) + 1
            elif line.startswith("'", index + 2):
                end = index + 3
            else:
                end = 0
            if end > 0:
                out.append(" " * (end - index))
                index = end
                continue
        out.append(char)
        index += 1
    return "".join(out)


class Block:
    def __init__(self, open_line, in_test, is_test, is_closure):
        self.open_line = open_line
        self.close_line = None
        self.in_test = in_test
        self.is_test = is_test
        self.is_closure = is_closure


def find_blocks(masked):
    """Returns the statement blocks: the bodies of functions, tests, closures and control statements."""
    blocks = []
    stack = []
    line_head = []
    for number, text in enumerate(masked):
        head = text.strip()
        leading = len(head) - len(head.lstrip(")]}"))
        if 0 < leading <= len(stack):
            opened = stack[-leading][1]
            head = line_head[opened]
            if opened > 0 and re.search(r"\bmatch$", masked[opened - 1].strip()):
                head = "match " + head
        line_head.append(head)
        for position, char in enumerate(text):
            if char in "([":
                stack.append((char, number, None))
            elif char == "{":
                kind = classify_brace(text, position, head)
                parent_in_test = any(entry[2] is not None and entry[2].in_test for entry in stack)
                block = None
                if kind == "stmt":
                    prefix = text[:position].strip()
                    is_test = bool(MBT_TEST.match(prefix))
                    block = Block(number, parent_in_test or is_test, is_test, prefix.endswith("=>"))
                    blocks.append(block)
                stack.append((char, number, block))
            elif char in ")]}":
                if not stack:
                    continue
                entry = stack.pop()
                if char == "}" and entry[2] is not None and text[:position].strip() == "":
                    entry[2].close_line = number
    return [block for block in blocks if block.close_line is not None]


def classify_brace(text, position, head):
    if text[position + 1 :].strip() != "":
        return "other"
    prefix = text[:position].rstrip()
    if prefix.strip() == "":
        return "other"
    if prefix.endswith("=>"):
        return "stmt"
    if re.search(r"\bcatch$", prefix):
        return "arms"
    if MBT_OTHER_PREFIX.search(prefix):
        return "other"
    if MBT_MATCH.search(head) and not prefix.endswith("else"):
        return "arms"
    return "stmt"


class Statement:
    def __init__(self, lead, start, end):
        self.lead = lead
        self.start = start
        self.end = end


def split_statements(lines, masked, depth_at_start, block):
    first = block.open_line + 1
    last = block.close_line - 1
    base = depth_at_start[first] if first <= last + 1 and first < len(depth_at_start) else None
    starts = []
    previous_code = None
    for number in range(first, last + 1):
        text = masked[number].strip()
        if text == "":
            if lines[number].strip() == "" or lines[number].lstrip().startswith("//"):
                continue
        if lines[number].lstrip().startswith("//"):
            continue
        is_start = depth_at_start[number] == base
        if is_start and previous_code is not None and masked[previous_code].rstrip().endswith(MBT_CONTINUED):
            is_start = False
        if is_start and text.startswith(MBT_CONTINUING_START):
            is_start = False
        if is_start:
            starts.append(number)
        previous_code = number
    statements = []
    for index, start in enumerate(starts):
        lead = start
        while lead - 1 > block.open_line and lines[lead - 1].lstrip().startswith("//"):
            lead -= 1
        statements.append([lead, start, None])
    for index, statement in enumerate(statements):
        limit = statements[index + 1][0] - 1 if index + 1 < len(statements) else last
        end = limit
        while end > statement[1] and (lines[end].strip() == "" or lines[end].lstrip().startswith("//")):
            end -= 1
        statement[2] = end
    return [Statement(*statement) for statement in statements]


def mbt_is_flow(statement, masked):
    head = masked[statement.start].strip()
    if statement.end == statement.start:
        return False
    return bool(MBT_FLOW.match(head) or MBT_CLOSURE_END.search(head))


def mbt_binds_for_head(before, after, masked):
    """Tells whether the line before reads, in its head, a variable the single line before it just bound."""
    if before.end != before.start or mbt_is_flow(after, masked) is False:
        return False
    bound = MBT_LET.match(masked[before.start].strip())
    head = MBT_HEAD_PREFIX.sub("", masked[after.start].strip())
    if bound is None or not re.match(r"^(?:if|match|for|while)\b", head):
        return False
    names = re.findall(r"[A-Za-z_]\w*", bound.group(1).split(":")[0])
    return any(re.search(rf"(?<![\w.]){name}\b", head) for name in names if name not in ("mut", "_"))


def mbt_violations(path, lines):
    masked = [mask_mbt_line(line) for line in lines]
    depth_at_start = []
    depth = 0
    for text in masked:
        depth_at_start.append(depth)
        for char in text:
            if char in "([{":
                depth += 1
            elif char in ")]}":
                depth -= 1
    is_test_file = path.name.endswith("test.mbt")
    found = {}
    for block in find_blocks(masked):
        if block.close_line - block.open_line < 2:
            continue
        statements = split_statements(lines, masked, depth_at_start, block)
        for before, after in zip(statements, statements[1:]):
            if lines[after.lead - 1].strip() == "":
                continue
            heads = (masked[before.start].strip(), masked[after.start].strip())
            if any(MBT_DEFER.match(head) for head in heads):
                continue
            if mbt_binds_for_head(before, after, masked):
                continue
            if mbt_is_flow(before, masked) or mbt_is_flow(after, masked):
                found[after.lead] = FLOW_MESSAGE
        if is_test_file and block.in_test and (block.is_test or block.is_closure):
            for index in range(1, len(statements)):
                group = statements[index]
                previous = statements[index - 1]
                if not MBT_ASSERT.match(masked[group.start].strip()):
                    continue
                if MBT_ASSERT.match(masked[previous.start].strip()) or MBT_DEFER.match(masked[previous.start].strip()):
                    continue
                if lines[group.lead - 1].strip() != "":
                    found.setdefault(group.lead, ASSERT_MESSAGE)
    return found


def python_statement_lead(lines, node):
    start = node.lineno
    for decorator in getattr(node, "decorator_list", []):
        start = min(start, decorator.lineno)
    while start - 1 >= 1 and lines[start - 2].lstrip().startswith("#"):
        start -= 1
    return start


PY_FLOW = (
    ast.If,
    ast.For,
    ast.AsyncFor,
    ast.While,
    ast.Try,
    ast.With,
    ast.AsyncWith,
    ast.Match,
    ast.FunctionDef,
    ast.AsyncFunctionDef,
)


def py_is_flow(node):
    return isinstance(node, PY_FLOW) and node.end_lineno > node.lineno


def py_is_assert(node):
    if isinstance(node, ast.Assert):
        return True
    if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call):
        function = node.value.func
        return isinstance(function, ast.Attribute) and function.attr.startswith("assert")
    return False


def py_head_names(node):
    heads = {
        ast.If: lambda n: [n.test],
        ast.While: lambda n: [n.test],
        ast.For: lambda n: [n.iter],
        ast.AsyncFor: lambda n: [n.iter],
        ast.With: lambda n: [item.context_expr for item in n.items],
        ast.AsyncWith: lambda n: [item.context_expr for item in n.items],
        ast.Match: lambda n: [n.subject],
    }
    select = heads.get(type(node))
    if select is None:
        return set()
    return {name.id for expression in select(node) for name in ast.walk(expression) if isinstance(name, ast.Name)}


def py_feeds_head(before, after):
    """Tells whether the one-line assignment before is read in the head of the statement after."""
    if not isinstance(before, (ast.Assign, ast.AnnAssign)) or before.end_lineno != before.lineno:
        return False
    targets = before.targets if isinstance(before, ast.Assign) else [before.target]
    bound = {name.id for target in targets for name in ast.walk(target) if isinstance(name, ast.Name)}
    return bool(bound & py_head_names(after))


def py_body_lists(node):
    for field in ("body", "orelse", "finalbody"):
        body = getattr(node, field, None)
        if isinstance(body, list) and body and isinstance(body[0], ast.stmt):
            yield body
    for handler in getattr(node, "handlers", []):
        yield handler.body
    for case in getattr(node, "cases", []):
        yield case.body


def py_check_body(lines, body, found, is_test):
    for before, after in zip(body, body[1:]):
        lead = python_statement_lead(lines, after)
        if lines[lead - 2].strip() == "":
            continue
        if py_feeds_head(before, after):
            continue
        if py_is_flow(before) or py_is_flow(after):
            found[lead] = FLOW_MESSAGE
    if is_test:
        for index in range(1, len(body)):
            if py_is_assert(body[index]) and not py_is_assert(body[index - 1]):
                lead = python_statement_lead(lines, body[index])
                if lines[lead - 2].strip() != "":
                    found.setdefault(lead, ASSERT_MESSAGE)
    for statement in body:
        is_with = isinstance(statement, (ast.With, ast.AsyncWith))
        for inner in py_body_lists(statement):
            py_check_body(lines, inner, found, is_test and is_with)


def py_violations(path, lines):
    tree = ast.parse("\n".join(lines))
    found = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            is_test = node.name.startswith("test") and not path.name.startswith("__")
            py_check_body(lines, node.body, found, is_test)
    return {line - 1: message for line, message in found.items()}


def violations(path, lines):
    if path.suffix == ".mbt":
        return mbt_violations(path, lines)
    return py_violations(path, lines)


def tracked_files():
    listed = subprocess.run(
        ["git", "ls-files", "*.mbt", "test/*.py"], check=True, capture_output=True, text=True
    ).stdout.split("\n")
    return [Path(name) for name in listed if name]


def main(arguments):
    fix = "--fix" in arguments
    names = [argument for argument in arguments if argument != "--fix"]
    paths = [Path(name) for name in names if name.endswith((".mbt", ".py"))] if names else tracked_files()
    failed = False
    for path in paths:
        text = path.read_text(encoding="utf-8")
        lines = text.split("\n")
        found = violations(path, lines)
        if not found:
            continue
        if fix:
            for number in sorted(found, reverse=True):
                lines.insert(number, "")
            path.write_text("\n".join(lines), encoding="utf-8")
            continue
        failed = True
        for number in sorted(found):
            print(f"{path}:{number + 1}: {found[number]}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
