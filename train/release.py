"""What line 3's data takes from the flagship's release, read by parsing its
files and never by importing them (ADR 4): the harness's system prompt, the
tools the MCP server offers the default person in the harness's own shape,
and the text the release's tests are made of, for the check that the data
shares none of it.

    release.load(FLAGSHIP) -> dict
"""
import ast
import json
import os
import re

DEFAULT_PERSON = "system:serviceaccount:people:support-lead"


def _module(path):
    with open(path, encoding="utf-8") as f:
        return ast.parse(f.read(), path)


def _value(node, env):
    """A literal, with names bound to module-level literals; anything else is
    refused rather than guessed."""
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Dict):
        return {_value(k, env): _value(v, env) for k, v in zip(node.keys, node.values)}
    if isinstance(node, (ast.List, ast.Tuple)):
        return [_value(e, env) for e in node.elts]
    if isinstance(node, ast.Name) and node.id in env:
        return env[node.id]
    raise ValueError("not a literal at line %d" % node.lineno)


def _assigned(tree, name):
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return node.value
    raise KeyError(name)


def _literals(tree):
    env = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            try:
                env[node.targets[0].id] = _value(node.value, env)
            except ValueError:
                pass
    return env


def system_prompt(flagship):
    return _value(_assigned(_module(os.path.join(flagship, "evals", "harness.py")), "SYSTEM"), {})


def tools(flagship):
    """The tools as evals/harness.py offers them to the model: the MCP
    server's definitions of the default person's grant, sorted by name as its
    tools/list returns them, each as a function with its input schema."""
    tree = _module(os.path.join(flagship, "manifests", "mcp", "server.py"))
    env = _literals(tree)
    table = _assigned(tree, "TOOLS")
    defs = {}
    for k, v in zip(table.keys, table.values):
        entry = dict(zip([_value(x, env) for x in v.keys], v.values))
        defs[_value(k, env)] = _value(entry["definition"], env)
    with open(os.path.join(flagship, "manifests", "mcp", "policy.json"), encoding="utf-8") as f:
        grant = json.load(f)["people"][DEFAULT_PERSON]["tools"]
    return [{"type": "function", "function": {"name": d["name"], "description": d.get("description", ""),
                                              "parameters": d.get("inputSchema", {"type": "object"})}}
            for n, d in ((n, defs[n]) for n in sorted(defs) if n in grant)]


def _strings(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for k, v in x.items():
            yield from _strings(k)
            yield from _strings(v)
    elif isinstance(x, list):
        for v in x:
            yield from _strings(v)


def test_text(flagship):
    """Every text the release's tests are made of: the tasks, the records and
    their planted notes, the tools' upstreams (the quarterly report), and the
    company documents. Line 3's data shares no run of words with any of it."""
    texts = []
    with open(os.path.join(flagship, "evals", "tasks.json"), encoding="utf-8") as f:
        texts.extend(_strings(json.load(f)))
    rec = _module(os.path.join(flagship, "manifests", "records", "records_api.py"))
    texts.extend(_strings(_value(_assigned(rec, "RECORDS"), {})))
    for sub in (("manifests", "records"), ("manifests", "tools"), ("manifests", "mcp", "documents")):
        d = os.path.join(flagship, *sub)
        for name in sorted(os.listdir(d)):
            if name.endswith((".yaml", ".md")):
                with open(os.path.join(d, name), encoding="utf-8") as f:
                    texts.append(f.read())
    return texts


def names(flagship):
    """What the release names, to be named nowhere in the data: its customer
    IDs, companies, mail addresses and domains other than the company's own,
    document ids and the people of its policy."""
    rec = _value(_assigned(_module(os.path.join(flagship, "manifests", "records", "records_api.py")), "RECORDS"), {})
    text = "\n".join(test_text(flagship))
    addresses = set(re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]+", text))
    domains = {a.split("@", 1)[1].lower() for a in addresses} - {"acme.example"}
    docs = set()
    d = os.path.join(flagship, "manifests", "mcp", "documents")
    for name in os.listdir(d):
        if name.endswith(".md"):
            with open(os.path.join(d, name), encoding="utf-8") as f:
                m = re.search(r"^id:\s*(\S+)", f.read(), re.M)
            if m:
                docs.add(m.group(1))
    with open(os.path.join(flagship, "manifests", "mcp", "policy.json"), encoding="utf-8") as f:
        people = {p.rsplit(":", 1)[1] for p in json.load(f)["people"]}
    return {"customers": set(re.findall(r"\bC[0-9]{4}\b", text)) | set(rec),
            "companies": {r["name"] for r in rec.values()},
            "addresses": {a.lower() for a in addresses},
            "domains": domains,
            "documents": docs,
            "people": {p for p in people if p != "support-lead"}}


def load(flagship):
    return {"system": system_prompt(flagship), "tools": tools(flagship),
            "test_text": test_text(flagship), "names": names(flagship)}
