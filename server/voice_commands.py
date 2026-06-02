"""
Bilingual (English + Italian) verbal-command interpreter.

Turns an ASR transcript into a sequence of typing + key actions for tmux. Speech
gives words, not symbols — so spoken commands like "slash" / "barra", "open paren"
/ "parentesi aperta", "enter" / "invio" become `/`, `(`, the Enter key, etc.

Matching is case-insensitive and accent-insensitive (so "più"/"piu",
"maiuscolo" match regardless of how the ASR renders accents), and only applies to
COMMAND words — dictated prose keeps its original text and accents.

interpret(text) -> list[Action]   where Action = ("type", str) | ("key", str)
cheatsheet()    -> grouped rules for the app to display.
"""

from __future__ import annotations

import unicodedata

# Action key names map to tmux send-keys key names in voice_server.execute_actions.
# "Newline" is resolved to the app-appropriate newline-without-submit sequence.

# Each rule: kind + payload + bilingual triggers + a display label/group.
RULES: list[dict] = [
    # ── keys ────────────────────────────────────────────────────────────────
    {"group": "keys", "label": "send ⏎", "kind": "key", "key": "Enter",
     "triggers": ["enter", "submit", "send", "send it", "go ahead",
                  "invio", "invia", "manda", "manda messaggio"]},
    {"group": "keys", "label": "newline ⇧⏎", "kind": "key", "key": "Newline",
     "triggers": ["new line", "newline", "line break", "shift enter", "shift-enter",
                  "a capo", "nuova riga", "shift invio", "shift-invio", "vai a capo"]},
    {"group": "keys", "label": "tab", "kind": "key", "key": "Tab",
     "triggers": ["tab", "tabulazione"]},
    {"group": "keys", "label": "escape", "kind": "key", "key": "Escape",
     "triggers": ["escape", "esc"]},
    {"group": "keys", "label": "backspace", "kind": "key", "key": "BSpace",
     "triggers": ["backspace", "scratch that", "cancella", "cancella quello"]},

    # ── slashes / paths ──────────────────────────────────────────────────────
    {"group": "paths", "label": "/", "kind": "char", "char": "/",
     "triggers": ["slash", "forward slash"]},
    {"group": "paths", "label": "\\", "kind": "char", "char": "\\",
     "triggers": ["backslash", "barra rovesciata", "barra inversa"]},
    {"group": "paths", "label": "~", "kind": "char", "char": "~",
     "triggers": ["tilde"]},
    {"group": "paths", "label": ".", "kind": "char", "char": ".",
     "triggers": ["dot", "period", "punto"]},
    {"group": "paths", "label": ",", "kind": "char", "char": ",",
     "triggers": ["comma", "virgola"]},
    {"group": "paths", "label": "-", "kind": "char", "char": "-",
     "triggers": ["dash", "hyphen", "trattino", "meno"]},
    {"group": "paths", "label": "_", "kind": "char", "char": "_",
     "triggers": ["underscore", "trattino basso", "sottolineato"]},
    {"group": "paths", "label": "(glue)", "kind": "glue",
     "triggers": ["no space", "nospace", "senza spazio", "attaccato"]},

    # ── symbols ──────────────────────────────────────────────────────────────
    {"group": "symbols", "label": "@", "kind": "char", "char": "@",
     "triggers": ["at sign", "chiocciola"]},  # bare "at" is too common in prose
    {"group": "symbols", "label": "#", "kind": "char", "char": "#",
     "triggers": ["hash", "pound", "number sign", "cancelletto", "diesis"]},
    {"group": "symbols", "label": "$", "kind": "char", "char": "$",
     "triggers": ["dollar", "dollar sign", "dollaro"]},
    {"group": "symbols", "label": "%", "kind": "char", "char": "%",
     "triggers": ["percent", "percento", "per cento"]},
    {"group": "symbols", "label": "^", "kind": "char", "char": "^",
     "triggers": ["caret", "circumflex", "accento circonflesso"]},
    {"group": "symbols", "label": "&", "kind": "char", "char": "&",
     "triggers": ["ampersand", "and sign", "e commerciale"]},
    {"group": "symbols", "label": "*", "kind": "char", "char": "*",
     "triggers": ["star", "asterisk", "asterisco"]},
    {"group": "symbols", "label": "|", "kind": "char", "char": "|",
     "triggers": ["pipe", "vertical bar", "barra verticale", "barra"]},
    {"group": "symbols", "label": "+", "kind": "char", "char": "+",
     "triggers": ["plus", "più", "piu"]},
    {"group": "symbols", "label": "=", "kind": "char", "char": "=",
     "triggers": ["equals", "equal sign", "uguale"]},
    {"group": "symbols", "label": ":", "kind": "char", "char": ":",
     "triggers": ["colon", "due punti"]},
    {"group": "symbols", "label": ";", "kind": "char", "char": ";",
     "triggers": ["semicolon", "punto e virgola"]},
    {"group": "symbols", "label": "?", "kind": "char", "char": "?",
     "triggers": ["question mark", "punto interrogativo", "punto di domanda"]},
    {"group": "symbols", "label": "!", "kind": "char", "char": "!",
     "triggers": ["bang", "exclamation", "exclamation mark", "punto esclamativo"]},
    {"group": "symbols", "label": "<", "kind": "char", "char": "<",
     "triggers": ["less than", "left angle", "minore"]},
    {"group": "symbols", "label": ">", "kind": "char", "char": ">",
     "triggers": ["greater than", "right angle", "maggiore"]},

    # ── quotes / backticks ───────────────────────────────────────────────────
    {"group": "quotes", "label": "`", "kind": "char", "char": "`",
     "triggers": ["backtick", "grave", "accento grave", "apice inverso"]},
    {"group": "quotes", "label": "\"", "kind": "char", "char": "\"",
     "triggers": ["double quote", "quote", "virgolette", "virgolette doppie"]},
    {"group": "quotes", "label": "'", "kind": "char", "char": "'",
     "triggers": ["single quote", "apostrophe", "apostrofo", "apice"]},
    {"group": "quotes", "label": "```", "kind": "fence",
     "triggers": ["code block", "triple backtick", "triple backticks",
                  "three backticks", "three backtick", "fence",
                  "blocco di codice", "blocco codice", "tre backtick", "tre apici"]},
    {"group": "quotes", "label": "``` (close)", "kind": "char", "char": "```",
     "triggers": ["end code block", "close code block", "chiudi blocco",
                  "fine blocco"]},

    # ── brackets: open/close + wrap-next-word ────────────────────────────────
    {"group": "brackets", "label": "(", "kind": "char", "char": "(",
     "triggers": ["open paren", "open parenthesis", "left paren",
                  "parentesi aperta", "aperta parentesi", "parentesi tonda aperta"]},
    {"group": "brackets", "label": ")", "kind": "char", "char": ")",
     "triggers": ["close paren", "right paren", "close parenthesis",
                  "parentesi chiusa", "chiusa parentesi", "parentesi tonda chiusa"]},
    {"group": "brackets", "label": "[", "kind": "char", "char": "[",
     "triggers": ["open bracket", "left bracket", "open square",
                  "parentesi quadra aperta", "quadra aperta"]},
    {"group": "brackets", "label": "]", "kind": "char", "char": "]",
     "triggers": ["close bracket", "right bracket", "close square",
                  "parentesi quadra chiusa", "quadra chiusa"]},
    {"group": "brackets", "label": "{", "kind": "char", "char": "{",
     "triggers": ["open brace", "left brace", "open curly",
                  "parentesi graffa aperta", "graffa aperta"]},
    {"group": "brackets", "label": "}", "kind": "char", "char": "}",
     "triggers": ["close brace", "right brace", "close curly",
                  "parentesi graffa chiusa", "graffa chiusa"]},
    {"group": "wrap", "label": "(…)", "kind": "wrap", "open": "(", "close": ")",
     "triggers": ["in parens", "in parentheses", "tra parentesi", "fra parentesi"]},
    {"group": "wrap", "label": "[…]", "kind": "wrap", "open": "[", "close": "]",
     "triggers": ["in brackets", "in square brackets", "tra parentesi quadre"]},
    {"group": "wrap", "label": "{…}", "kind": "wrap", "open": "{", "close": "}",
     "triggers": ["in braces", "in curlies", "tra parentesi graffe"]},
    {"group": "wrap", "label": "\"…\"", "kind": "wrap", "open": "\"", "close": "\"",
     "triggers": ["in quotes", "tra virgolette"]},
    {"group": "wrap", "label": "`…`", "kind": "wrap", "open": "`", "close": "`",
     "triggers": ["in backticks", "tra backtick"]},

    # ── case / naming ────────────────────────────────────────────────────────
    {"group": "case", "label": "ALL CAPS", "kind": "case", "mode": "upper",
     "triggers": ["all caps", "caps on", "caps lock", "uppercase",
                  "maiuscolo", "tutto maiuscolo", "maiuscole"]},
    {"group": "case", "label": "lower", "kind": "case", "mode": "lower",
     "triggers": ["lowercase", "minuscolo", "minuscole"]},
    {"group": "case", "label": "caps off", "kind": "case", "mode": "none",
     "triggers": ["caps off", "end caps", "normal case", "normale"]},
    {"group": "case", "label": "Capitalize next", "kind": "case_once", "mode": "cap",
     "triggers": ["capital", "capitalize", "maiuscola"]},

    # ── literal escape ───────────────────────────────────────────────────────
    {"group": "escape", "label": "literal next", "kind": "literal",
     "triggers": ["literal", "literally", "letterale", "letteralmente"]},
]

_PUNCT = ".,!?;:\"'()[]{}"
# Closing brackets always get a space after them; connectors (/ ~ - . :) glue to
# the following word (better for paths, filenames, key:value, domains).
_CLOSERS = {")", "]", "}"}


def _fold(s: str) -> str:
    """Lowercase + strip accents — used only for matching command words."""
    return "".join(
        c for c in unicodedata.normalize("NFKD", s.lower()) if not unicodedata.combining(c)
    )


def _norm(tok: str) -> str:
    return _fold(tok.strip(_PUNCT))


# Build the phrase -> rule lookup and the longest phrase length.
_PHRASES: dict[str, dict] = {}
for _r in RULES:
    for _t in _r["triggers"]:
        _PHRASES[" ".join(_fold(w) for w in _t.split())] = _r
_MAXW = max(len(p.split()) for p in _PHRASES)


def interpret(transcript: str) -> list[tuple[str, str]]:
    tokens = transcript.split()
    n = len(tokens)
    actions: list[tuple[str, str]] = []
    buf: list[tuple[str, bool]] = []  # (text, glue_before)
    next_glue = False
    case_mode = "none"
    cap_once = False
    literal_once = False
    pending_close: str | None = None

    def flush():
        nonlocal buf
        if buf:
            s = buf[0][0]
            for piece, glue in buf[1:]:
                s += ("" if glue else " ") + piece
            actions.append(("type", s))
            buf = []

    def style(w: str) -> str:
        nonlocal cap_once
        if case_mode == "upper":
            return w.upper()
        if case_mode == "lower":
            return w.lower()
        if cap_once:
            cap_once = False
            return w[:1].upper() + w[1:]
        return w

    def emit_symbol(ch: str):
        nonlocal next_glue
        buf.append((ch, True))
        next_glue = ch not in _CLOSERS

    def emit_word(w: str):
        nonlocal next_glue, pending_close
        buf.append((style(w), next_glue))
        next_glue = False
        if pending_close is not None:
            buf.append((pending_close, True))
            next_glue = False  # a wrapped group is complete — space before the next word
            pending_close = None

    i = 0
    while i < n:
        if literal_once:
            emit_word(tokens[i])
            literal_once = False
            i += 1
            continue

        matched = None
        mlen = 0
        for w in range(min(_MAXW, n - i), 0, -1):
            phrase = " ".join(_norm(t) for t in tokens[i:i + w])
            if phrase in _PHRASES:
                matched, mlen = _PHRASES[phrase], w
                break

        if matched is None:
            emit_word(tokens[i])
            i += 1
            continue

        i += mlen
        kind = matched["kind"]
        if kind == "char":
            emit_symbol(matched["char"])
        elif kind == "fence":
            # Don't glue the fence to the previous word ("a ```python", not
            # "a```python"), but do glue an immediately following language word.
            buf.append(("```", next_glue))
            next_glue = True
        elif kind == "key":
            flush()
            actions.append(("key", matched["key"]))
        elif kind == "case":
            case_mode = matched["mode"]
        elif kind == "case_once":
            cap_once = True
        elif kind == "literal":
            literal_once = True
        elif kind == "glue":
            next_glue = True
        elif kind == "wrap":
            emit_symbol(matched["open"])
            pending_close = matched["close"]

    flush()
    return actions


def render(actions: list[tuple[str, str]]) -> str:
    """Human-readable preview of what will be typed (keys shown as ⟨Key⟩)."""
    out = []
    for kind, val in actions:
        out.append(val if kind == "type" else f"⟨{val}⟩")
    return "".join(out)


def cheatsheet() -> list[dict]:
    """Grouped rules for the app to display: [{group, items:[{label, triggers}]}]."""
    groups: dict[str, list[dict]] = {}
    for r in RULES:
        groups.setdefault(r["group"], []).append(
            {"label": r["label"], "triggers": r["triggers"]}
        )
    return [{"group": g, "items": items} for g, items in groups.items()]


if __name__ == "__main__":
    for t in [
        "slash context",
        "tilde slash Code slash my dash project slash",
        "barra context",
        "git status invio",
        "open paren foo close paren",
        "tra parentesi ciao",
        "all caps deploy now caps off please",
        "maiuscolo errore minuscolo",
        "make a code block python new line print hello",
        "due punti punto e virgola",
        "literal slash is a word",
    ]:
        print(f"{t!r}\n   -> {render(interpret(t))!r}\n")
