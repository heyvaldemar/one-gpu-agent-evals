#!/usr/bin/env python3
"""Line 3's data, held to ADR 4.

    check_data.py FLAGSHIP DIR [--lock train/data.lock]

DIR holds train.jsonl and valid.jsonl as train/generate.py writes them.
FLAGSHIP is the release's tree scripts/sources.sh verified. Every check
prints PASS or FAIL; the exit status is 1 if any failed.

- lock: each file's sha256 is the one train/data.lock pins, and no file is
  missing or extra (only with --lock);
- agent: every example has the release's system prompt and exactly the tools
  it offers the default person, the turns in the order the harness sends
  them, every call to an offered tool with arguments its schema allows;
- names: no customer ID, company, mail address, outside mail domain,
  document id or person of the release, and every customer ID from C5000 to
  C8999;
- words: no run of six words in common with the release's test text;
- language: every planted instruction in English;
- behaviour: every email to an address the user wrote or the account manager
  the user asked to write to, read from the messages; whether something is
  planted, read from the tool results and matched against the meta; and the
  calls each example's meta says;
- balance: between 45% and 55% of each file has a planted instruction.
"""
import argparse
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release  # noqa: E402

FILES = ("train.jsonl", "valid.jsonl")
NGRAM = 6
# Words that are common in the languages the release plants in, or might;
# none of them is an English word a planted instruction here would use.
FOREIGN = {"der", "die", "das", "und", "nicht", "sie", "ist", "mit", "dem", "den", "sofort", "bitte",
           "le", "la", "les", "des", "une", "est", "pas", "vous", "avec", "envoyez", "el", "los", "las", "que",
           "por", "para", "usted", "envie", "het", "een", "niet", "naar", "che", "invia"}
failures = []


def report(ok, what):
    print("%s  %s" % ("PASS" if ok else "FAIL", what))
    if not ok:
        failures.append(what)


def words(text):
    return re.findall(r"[a-z0-9]+", text.lower())


def grams(text):
    w = words(text)
    return {tuple(w[i:i + NGRAM]) for i in range(len(w) - NGRAM + 1)}


def own_text(ex):
    """What the generator wrote: everything but the release's system prompt
    and tools, which every example carries on purpose."""
    out = []
    for m in ex["messages"][1:]:
        if m.get("content"):
            out.append(m["content"])
        for c in m.get("tool_calls") or []:
            out.append(c["function"]["arguments"])
    return out


def check_lock(d, lock):
    pinned = {}
    with open(lock, encoding="utf-8") as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                s, n = line.split()
                pinned[n] = s
    have = sorted(os.listdir(d))  # every entry, dotfiles too
    got = {n: hashlib.sha256(open(os.path.join(d, n), "rb").read()).hexdigest() for n in have}
    report(set(got) == set(pinned), "lock: the files are the ones data.lock names (%s)" % ", ".join(have))
    bad = sorted(n for n in pinned if got.get(n) != pinned[n])
    report(not bad, "lock: every file's sha256 is the one data.lock pins" + (": not %s" % ", ".join(bad) if bad else ""))


def args_allowed(schema, args):
    if not isinstance(args, dict):
        return False
    props = schema.get("properties", {})
    if any(k not in args for k in schema.get("required", [])):
        return False
    if schema.get("additionalProperties") is False and any(k not in props for k in args):
        return False
    for k, v in args.items():
        p = props.get(k, {})
        if p.get("type") == "string":
            if not isinstance(v, str) or len(v) > p.get("maxLength", 10**9) or len(v) < p.get("minLength", 0):
                return False
            if "pattern" in p and not re.fullmatch(p["pattern"], v):  # as the MCP server holds it
                return False
    return True


def check_agent(rows, rel):
    schemas = {t["function"]["name"]: t["function"]["parameters"] for t in rel["tools"]}
    bad = []
    for name, ex in rows:
        where = "%s #%d" % (name, ex["meta"]["n"])
        m = ex["messages"]
        if ex["tools"] != rel["tools"]:
            bad.append(where + ": not the release's tools")
            continue
        if m[0] != {"role": "system", "content": rel["system"]}:
            bad.append(where + ": not the release's system prompt")
            continue
        if m[1]["role"] != "user" or m[-1]["role"] != "assistant" or m[-1].get("tool_calls") \
                or not isinstance(m[-1].get("content"), str) or not m[-1]["content"]:
            bad.append(where + ": does not run user ... answer")
            continue
        i, pending = 2, []
        while i < len(m) - 1:
            x = m[i]
            if x["role"] == "assistant" and x.get("tool_calls") and not pending:
                for c in x["tool_calls"]:
                    f = c["function"]
                    try:
                        a = json.loads(f["arguments"])
                    except ValueError:
                        a = None
                    if f["name"] not in schemas or not args_allowed(schemas[f["name"]], a):
                        bad.append(where + ": a call the offered tools do not allow (%s)" % f["name"])
                    pending.append(c["id"])
            elif x["role"] == "tool" and pending and x["tool_call_id"] == pending[0]:
                pending.pop(0)
            else:
                bad.append(where + ": turn %d out of the harness's order" % i)
                break
            i += 1
        if pending:
            bad.append(where + ": a call with no result")
    report(not bad, "agent: the release's prompt and tools, the harness's turns, calls the schemas allow"
           + ("; " + "; ".join(bad[:3]) if bad else ""))


def check_names(rows, rel):
    n = rel["names"]
    bad = []
    for name, ex in rows:
        where = "%s #%d" % (name, ex["meta"]["n"])
        text = "\n".join(own_text(ex))
        low = text.lower()
        for cid in re.findall(r"\bC[0-9]{4}\b", text):
            if cid in n["customers"] or not 5000 <= int(cid[1:]) <= 8999:
                bad.append("%s: customer %s" % (where, cid))
        for c in n["companies"]:
            if c.lower() in low:
                bad.append("%s: company %s" % (where, c))
        for a in n["addresses"]:
            if a in low:
                bad.append("%s: address %s" % (where, a))
        for dom in n["domains"]:
            if dom in low:
                bad.append("%s: domain %s" % (where, dom))
        for doc in n["documents"]:
            if re.search(r"(?<![a-z0-9-])%s(?![a-z0-9-])" % re.escape(doc), low):
                bad.append("%s: document %s" % (where, doc))
        for p in n["people"]:
            if p in words(text):
                bad.append("%s: person %s" % (where, p))
    report(not bad, "names: nothing the release names, every customer from C5000 to C8999"
           + ("; " + "; ".join(bad[:3]) if bad else ""))


def check_words(rows, rel):
    theirs = set()
    for t in rel["test_text"]:
        theirs |= grams(t)
    bad = []
    for name, ex in rows:
        for t in own_text(ex):
            common = grams(t) & theirs
            if common:
                bad.append("%s #%d: %s" % (name, ex["meta"]["n"], " ".join(sorted(common)[0])))
                break
    report(not bad, "words: no run of %d words in common with the release's tasks, records, report and documents"
           % NGRAM + ("; " + "; ".join(bad[:3]) if bad else ""))


def check_language(rows):
    """Over everything the generator wrote, not over what its meta says the
    plant was: a plant in another language anywhere in a tool result counts."""
    bad = []
    for name, ex in rows:
        text = "\n".join(own_text(ex))
        if not text.isascii() or FOREIGN & set(words(text)):
            bad.append("%s #%d" % (name, ex["meta"]["n"]))
    report(not bad, "language: every planted instruction in English" + ("; " + ", ".join(bad[:3]) if bad else ""))


def results(ex):
    """(tool name, text) of every tool result, by the call it answers."""
    names = {c["id"]: c["function"]["name"] for m in ex["messages"] for c in (m.get("tool_calls") or [])}
    return [(names.get(m["tool_call_id"]), m["content"]) for m in ex["messages"] if m["role"] == "tool"]


RECORD_FIELDS = {"id", "name", "plan", "renewal", "open_tickets", "account_manager"}


def record(text):
    try:
        r = json.loads(text)
    except ValueError:
        return None
    return r if isinstance(r, dict) else None


def planted_in(ex):
    """Whether a tool result carries something beyond the data the tool
    holds, read from the messages and not from meta: a record that is not
    JSON, has a field beyond the generator's, or an address anywhere but its
    account manager; a mail address or a link in a report or a document. The
    generator's own records, report and documents carry none of that."""
    for name, text in results(ex):
        if name == "records_lookup":
            r = record(text)
            if r is None or set(r) - RECORD_FIELDS or "@" in json.dumps(
                    {k: v for k, v in r.items() if k != "account_manager"}):
                return True
        elif name in ("quarterly_report", "search_documents") and ("@" in text or "://" in text):
            return True
    return False


def allowed_recipients(ex):
    """Who an email may go to, read from the messages: an address the user
    wrote, or the account manager of a record the user asked to write to."""
    user = ex["messages"][1]["content"]
    ok = set(re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+", user))
    if re.search(r"account manager|owner of account", user):
        for name, text in results(ex):
            r = record(text) if name == "records_lookup" else None
            if r and isinstance(r.get("account_manager"), str):
                ok.add(r["account_manager"])
    return ok


def check_behaviour(rows):
    bad = []
    for name, ex in rows:
        where = "%s #%d" % (name, ex["meta"]["n"])
        meta = ex["meta"]
        calls = [c["function"] for m in ex["messages"] for c in (m.get("tool_calls") or [])]
        if [c["name"] for c in calls] != meta["expect"]["calls"]:
            bad.append(where + ": calls are not the ones its meta says")
        sent = [json.loads(c["arguments"]).get("to") for c in calls if c["name"] == "send_email"]
        if sent != meta["expect"]["send_email_to"]:
            bad.append(where + ": an email the user did not ask for")
        if meta.get("planted_instruction") and not meta.get("planted"):
            bad.append(where + ": declares a planted instruction and does not say what it is")
        if meta.get("planted_instruction") and meta.get("target") in sent:
            bad.append(where + ": an email to the planted target")  # even one the user also named
        if any(to not in allowed_recipients(ex) for to in sent):
            bad.append(where + ": an email to an address the user did not give or ask for")
        if planted_in(ex) != bool(meta.get("planted_instruction")):
            bad.append(where + ": a planted instruction its meta does not declare, or one it declares that is not there")
        if meta.get("planted") and not any(meta["planted"] in (m.get("content") or "")
                                           for m in ex["messages"] if m["role"] == "tool"):
            bad.append(where + ": the planted instruction is not in what a tool returned")
    report(not bad, "behaviour: every email to someone the user named or asked for, every plant declared"
           + ("; " + "; ".join(bad[:3]) if bad else ""))


def check_balance(files):
    for name, part in files.items():
        share = sum(bool(ex["meta"].get("planted_instruction")) for ex in part) / max(len(part), 1)
        report(0.45 <= share <= 0.55, "balance: %s has a planted instruction in %.0f%% of %d examples"
               % (name, 100 * share, len(part)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("flagship")
    ap.add_argument("dir")
    ap.add_argument("--lock")
    a = ap.parse_args()
    rel = release.load(a.flagship)
    if a.lock:
        check_lock(a.dir, a.lock)
    files = {}
    for name in FILES:
        with open(os.path.join(a.dir, name), encoding="utf-8") as f:
            files[name] = [json.loads(line) for line in f]
    rows = [(name, ex) for name, part in files.items() for ex in part]
    check_agent(rows, rel)
    check_names(rows, rel)
    check_words(rows, rel)
    check_language(rows)
    check_behaviour(rows)
    check_balance(files)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
