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
     "triggers": ["all caps", "caps on", "caps lock", "caps mode", "uppercase",
                  "uppercase mode", "maiuscolo", "tutto maiuscolo", "maiuscole",
                  "modo maiuscolo"]},
    {"group": "case", "label": "lower", "kind": "case", "mode": "lower",
     "triggers": ["lowercase", "lowercase mode", "minuscolo", "minuscole",
                  "modo minuscolo"]},
    {"group": "case", "label": "caps off", "kind": "case", "mode": "none",
     "triggers": ["caps off", "caps mode stop", "caps mode off", "stop caps",
                  "end caps", "normal case", "normale"]},
    {"group": "case", "label": "Capitalize next", "kind": "case_once", "mode": "cap",
     "triggers": ["capital", "capitalize", "maiuscola"]},

    # ── markdown ─────────────────────────────────────────────────────────────
    {"group": "markdown", "label": "# heading", "kind": "prefix", "text": "# ",
     "triggers": ["heading", "title", "header", "titolo"]},
    {"group": "markdown", "label": "## heading", "kind": "prefix", "text": "## ",
     "triggers": ["heading two", "subheading", "sub heading", "sottotitolo"]},
    {"group": "markdown", "label": "### heading", "kind": "prefix", "text": "### ",
     "triggers": ["heading three", "sub subheading"]},
    {"group": "markdown", "label": "- bullet", "kind": "prefix", "text": "- ",
     "triggers": ["bullet", "bullet point", "list item", "punto elenco", "elenco puntato"]},
    {"group": "markdown", "label": "1. numbered", "kind": "prefix", "text": "1. ",
     "triggers": ["numbered item", "numbered list", "elenco numerato"]},
    {"group": "markdown", "label": "> quote", "kind": "prefix", "text": "> ",
     "triggers": ["quote block", "block quote", "blockquote", "citazione"]},
    {"group": "markdown", "label": "**bold**", "kind": "wrap", "open": "**", "close": "**",
     "triggers": ["bold", "grassetto"]},
    {"group": "markdown", "label": "*italic*", "kind": "wrap", "open": "*", "close": "*",
     "triggers": ["italic", "corsivo"]},
    {"group": "markdown", "label": "~~strike~~", "kind": "wrap", "open": "~~", "close": "~~",
     "triggers": ["strikethrough", "barrato"]},
    {"group": "markdown", "label": "---", "kind": "char", "char": "---",
     "triggers": ["horizontal rule", "divider", "linea orizzontale"]},

    # ── literal escape ───────────────────────────────────────────────────────
    {"group": "escape", "label": "literal next", "kind": "literal",
     "triggers": ["literal", "literally", "letterale", "letteralmente"]},

    # ── spelling mode ────────────────────────────────────────────────────────
    {"group": "spelling", "label": "spell ON", "kind": "spell_on",
     "triggers": ["spell", "spelling", "spell mode", "spelling mode", "spell it",
                  "spell out", "letter by letter", "compita", "compitazione",
                  "modo lettere", "lettera per lettera"]},
    {"group": "spelling", "label": "spell OFF", "kind": "spell_off",
     "triggers": ["end spell", "end spelling", "stop spelling", "stop spell",
                  "spell mode stop", "spell mode off", "end letters", "normal mode",
                  "fine compitazione", "fine lettere", "modo normale", "basta lettere"]},
]

_PUNCT = ".,!?;:\"'()[]{}"
# Closing brackets always get a space after them; connectors (/ ~ - . :) glue to
# the following word (better for paths, filenames, key:value, domains).
_CLOSERS = {")", "]", "}"}

# In spelling mode only these command kinds still apply; everything else becomes a
# letter (you're spelling a word, so "slash" etc. shouldn't be interpreted).
_SPELL_OK = {"spell_off", "key", "case", "case_once"}
_SPACE_WORDS = {"space", "spazio", "spacebar"}

# Spoken letter names -> letters (English + Italian + common ASR mishearings).
# Whisper transcribes spelled letters by their phonetic names ("L M R" -> "al em
# er"); this maps them back. Unknown tokens pass through unchanged (so an
# already-merged "cat" stays "cat").
SPELL_MAP = {
    "a": "a", "ay": "a", "eh": "a",
    "b": "b", "bee": "b", "be": "b", "bi": "b",
    "c": "c", "see": "c", "cee": "c", "ci": "c", "si": "c",
    "d": "d", "dee": "d", "di": "d",
    "e": "e", "ee": "e",
    "f": "f", "ef": "f", "eff": "f", "effe": "f",
    "g": "g", "gee": "g", "gi": "g", "ji": "g",
    "h": "h", "aitch": "h", "eich": "h", "acca": "h",
    "i": "i", "eye": "i",
    "j": "j", "jay": "j",
    "k": "k", "kay": "k", "kappa": "k",
    "l": "l", "el": "l", "ell": "l", "al": "l", "elle": "l",
    "m": "m", "em": "m", "emme": "m",
    "n": "n", "en": "n", "enne": "n",
    "o": "o", "oh": "o",
    "p": "p", "pee": "p", "pi": "p",
    "q": "q", "cue": "q", "queue": "q", "cu": "q", "qu": "q",
    "r": "r", "ar": "r", "are": "r", "er": "r", "erre": "r",
    "s": "s", "es": "s", "ess": "s", "esse": "s",
    "t": "t", "tee": "t", "ti": "t",
    "u": "u", "you": "u", "yu": "u",
    "v": "v", "vee": "v", "vu": "v", "vi": "v",
    "w": "w", "doubleu": "w", "dub": "w",
    "x": "x", "ex": "x", "ics": "x", "ix": "x",
    "y": "y", "why": "y", "wy": "y", "ipsilon": "y",
    "z": "z", "zee": "z", "zed": "z", "zeta": "z",
}


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

    spelling = False

    def emit_letter(ch: str):
        nonlocal next_glue, cap_once
        if case_mode == "upper":
            ch = ch.upper()
        elif case_mode == "lower":
            ch = ch.lower()
        elif cap_once:
            ch = ch.upper()
            cap_once = False
        buf.append((ch, next_glue))  # 1st letter spaces from prior word; rest glue
        next_glue = True

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

        # Spelling mode: most tokens become letters; only a few commands apply.
        if spelling and (matched is None or matched["kind"] not in _SPELL_OK):
            tok = _norm(tokens[i])
            if tok in _SPACE_WORDS:
                buf.append((" ", next_glue))
                next_glue = True
            else:
                emit_letter(SPELL_MAP.get(tok, tok))
            i += 1
            continue

        if matched is None:
            emit_word(tokens[i])
            i += 1
            continue

        i += mlen
        kind = matched["kind"]
        if kind == "spell_on":
            spelling = True
        elif kind == "spell_off":
            spelling = False
        elif kind == "char":
            emit_symbol(matched["char"])
        elif kind == "fence":
            # fence glues a following language word ("```python") but not the prev.
            buf.append(("```", next_glue))
            next_glue = True
        elif kind == "prefix":
            # markdown line prefixes ("## " / "- " / "> ") already end with a space.
            buf.append((matched["text"], next_glue))
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
