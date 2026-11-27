"""Vérification statique : variables globales lues ou créées par l'addon.

Attrape les fautes de frappe (variable inconnue = nil en jeu) et les variables locales oubliées
(qui deviennent globales et peuvent entrer en conflit avec d'autres addons).
Les globales autorisées sont celles de .luacheckrc (le même fichier sert à luacheck sur GitHub).

Usage : python tests/check_globals.py   (pip install luaparser)
"""
import re
import sys
from pathlib import Path
# Console Windows (cp1252) : on force l'UTF-8 pour les accents et les flèches
for _s in (sys.stdout, sys.stderr):
    if hasattr(_s, "reconfigure"):
        _s.reconfigure(encoding="utf-8", errors="replace")

from luaparser import ast, astnodes as N

ROOT = Path(__file__).resolve().parent.parent

LUA51 = set("""assert error ipairs pairs next pcall xpcall select tonumber tostring type unpack setmetatable
getmetatable rawget rawset rawequal string table math os coroutine debug print loadstring require _VERSION
collectgarbage getfenv setfenv module load dofile newproxy gcinfo io package""".split())


def allowed_globals():
    rc = (ROOT / ".luacheckrc").read_text(encoding="utf-8")
    def block(name):
        m = re.search(r"^" + name + r"\s*=\s*\{(.*?)^\}", rc, re.S | re.M) or re.search(name + r"\s*=\s*\{(.*?)\}", rc, re.S)
        return set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
    return block("globals"), block("read_globals")


class Checker:
    def __init__(self, fname):
        self.fname = fname
        self.scopes = [set()]
        self.reads, self.writes = {}, {}

    def declared(self, name):
        return any(name in s for s in self.scopes)

    def declare(self, name):
        self.scopes[-1].add(name)

    def push(self, names=()):
        self.scopes.append(set(names))

    def pop(self):
        self.scopes.pop()

    def line(self, node):
        return getattr(node, "line", None) or "?"

    def read(self, node):
        if not self.declared(node.id):
            self.reads.setdefault(node.id, self.line(node))

    def write(self, node):
        if not self.declared(node.id):
            self.writes.setdefault(node.id, self.line(node))

    def func(self, args, body, extra=()):
        self.push(extra)
        for a in args:
            if isinstance(a, N.Name):
                self.declare(a.id)
        self.visit(body)
        self.pop()

    def visit(self, node):
        if node is None or not isinstance(node, (N.Node, list)):
            return
        if isinstance(node, list):
            for n in node:
                self.visit(n)
            return
        if isinstance(node, N.Chunk):
            return self.visit(node.body)
        if isinstance(node, N.Block):
            self.push()
            self.visit(node.body)
            return self.pop()
        if isinstance(node, N.LocalAssign):
            self.visit(node.values)
            for t in node.targets:
                self.declare(t.id)
            return
        if isinstance(node, N.LocalFunction):
            self.declare(node.name.id)
            return self.func(node.args, node.body)
        if isinstance(node, N.Function):
            if isinstance(node.name, N.Name):
                self.write(node.name)
            else:
                self.visit(node.name)
            return self.func(node.args, node.body)
        if isinstance(node, N.Method):
            self.visit(node.source)
            return self.func(node.args, node.body, extra=("self",))
        if isinstance(node, N.AnonymousFunction):
            return self.func(node.args, node.body)
        if isinstance(node, N.Fornum):
            self.visit([node.start, node.stop, node.step])
            self.push([node.target.id])
            self.visit(node.body)
            return self.pop()
        if isinstance(node, N.Forin):
            self.visit(node.iter)
            self.push([t.id for t in node.targets])
            self.visit(node.body)
            return self.pop()
        if isinstance(node, N.Repeat):
            self.push()
            self.visit(node.body.body if isinstance(node.body, N.Block) else node.body)
            self.visit(node.test)
            return self.pop()
        if isinstance(node, N.Assign):
            self.visit(node.values)
            for t in node.targets:
                if isinstance(t, N.Name):
                    self.write(t)
                else:
                    self.visit(t)
            return
        if isinstance(node, N.Name):
            return self.read(node)
        if isinstance(node, N.Index):
            self.visit(node.value)
            if node.notation == N.IndexNotation.SQUARE:
                self.visit(node.idx)
            return
        if isinstance(node, N.Invoke):
            self.visit(node.source)
            return self.visit(node.args)
        if isinstance(node, N.Field):
            if getattr(node, "between_brackets", False):
                self.visit(node.key)
            return self.visit(node.value)
        # cas général : on parcourt les sous-nœuds
        for k, v in vars(node).items():
            if k.startswith("_") or k in ("comments", "line", "start_char", "stop_char", "wrapped"):
                continue
            if isinstance(v, (N.Node, list)):
                self.visit(v)


def main():
    globals_ok, read_ok = allowed_globals()
    toc = (ROOT / "AHLedger.toc").read_text(encoding="utf-8")
    files = [l.strip() for l in toc.splitlines() if l.strip().endswith(".lua")]
    problems = []
    for f in files:
        c = Checker(f)
        c.visit(ast.parse((ROOT / f).read_text(encoding="utf-8")))
        for name, line in sorted(c.writes.items()):
            if name not in globals_ok:
                problems.append(f"{f}:{line}: variable globale créée « {name} » (local oublié ?)")
        for name, line in sorted(c.reads.items()):
            if name not in globals_ok | read_ok | LUA51 and name not in c.writes:
                problems.append(f"{f}:{line}: variable globale inconnue « {name} » (faute de frappe, ou API à ajouter dans .luacheckrc)")
    for p in problems:
        print(p)
    print(f"{len(files)} fichiers vérifiés, {len(problems)} problème(s).")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
