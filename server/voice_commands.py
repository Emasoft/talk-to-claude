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
    # Arrow keys — navigate Claude's menus (AskUserQuestion) and the prompt
    # history. "arrow up/down" only (bare "up"/"down" would shadow the words).
    {"group": "keys", "label": "↑", "kind": "key", "key": "Up",
     "triggers": ["arrow up", "up arrow", "freccia su", "freccia in su"]},
    {"group": "keys", "label": "↓", "kind": "key", "key": "Down",
     "triggers": ["arrow down", "down arrow", "freccia giù", "freccia in giù"]},

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

    # ── quotes / backticks (OPEN/CLOSE, full names) ──────────────────────────
    {"group": "quotes", "label": "`", "kind": "char", "char": "`",
     "triggers": ["backtick", "grave", "accento grave", "apice inverso"]},
    {"group": "quotes", "label": "\"", "kind": "char", "char": "\"",
     "triggers": ["open quotes", "open double quotes", "apri virgolette",
                  "virgolette aperte"]},
    {"group": "quotes", "label": "\"", "kind": "char", "char": "\"",
     "triggers": ["close quotes", "close double quotes", "chiudi virgolette",
                  "virgolette chiuse"]},
    {"group": "quotes", "label": "'", "kind": "char", "char": "'",
     "triggers": ["apostrophe", "apostrofo", "single quote", "apice"]},
    {"group": "quotes", "label": "```", "kind": "fence",
     "triggers": ["open code block", "code block", "triple backticks",
                  "three backticks", "fence", "blocco di codice", "tre backtick"]},
    {"group": "quotes", "label": "``` (close)", "kind": "char", "char": "```",
     "triggers": ["close code block", "end code block", "chiudi blocco",
                  "fine blocco"]},

    # ── brackets: OPEN/CLOSE + wrap-next-word (full names — never "paren") ────
    {"group": "brackets", "label": "(", "kind": "char", "char": "(",
     "triggers": ["open parentheses", "open parenthesis",
                  "parentesi tonda aperta", "parentesi aperta", "aperta parentesi"]},
    {"group": "brackets", "label": ")", "kind": "char", "char": ")",
     "triggers": ["close parentheses", "close parenthesis",
                  "parentesi tonda chiusa", "parentesi chiusa", "chiusa parentesi"]},
    {"group": "brackets", "label": "[", "kind": "char", "char": "[",
     "triggers": ["open square brackets", "open square bracket",
                  "parentesi quadra aperta", "quadra aperta"]},
    {"group": "brackets", "label": "]", "kind": "char", "char": "]",
     "triggers": ["close square brackets", "close square bracket",
                  "parentesi quadra chiusa", "quadra chiusa"]},
    {"group": "brackets", "label": "{", "kind": "char", "char": "{",
     "triggers": ["open curly braces", "open curly brace",
                  "parentesi graffa aperta", "graffa aperta"]},
    {"group": "brackets", "label": "}", "kind": "char", "char": "}",
     "triggers": ["close curly braces", "close curly brace",
                  "parentesi graffa chiusa", "graffa chiusa"]},
    # (The "in parentheses"/"in quotes"/… wrap-next-word commands were removed —
    # the explicit OPEN/CLOSE pair covers them and was less ambiguous.)

    # ── case / naming ────────────────────────────────────────────────────────
    # CAPS is a START/STOP pair (rendered as one two-row cell in the app). We avoid
    # the word "off" entirely — ASR hears "caps off" as "caps of".
    {"group": "case", "label": "START CAPS MODE", "kind": "case", "mode": "upper",
     "pair": "caps", "role": "start",
     "triggers": ["start caps mode", "caps mode", "all caps", "caps on", "caps lock",
                  "uppercase", "uppercase mode", "maiuscolo", "tutto maiuscolo",
                  "maiuscole", "modo maiuscolo"]},
    {"group": "case", "label": "STOP CAPS MODE", "kind": "case", "mode": "none",
     "pair": "caps", "role": "stop",
     "triggers": ["stop caps mode", "caps mode stop", "stop caps",
                  "end caps", "normal case", "normale"]},
    {"group": "case", "label": "lowercase", "kind": "case", "mode": "lower",
     "triggers": ["lowercase", "lowercase mode", "minuscolo", "minuscole",
                  "modo minuscolo"]},
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

    # ── spelling mode (START/STOP pair) ──────────────────────────────────────
    {"group": "spelling", "label": "START SPELL MODE", "kind": "spell_on",
     "pair": "spell", "role": "start",
     "triggers": ["start spell mode", "spell mode", "spell", "spelling", "spelling mode",
                  "spell it", "spell out", "letter by letter", "compita", "compitazione",
                  "modo lettere", "lettera per lettera"]},
    {"group": "spelling", "label": "STOP SPELL MODE", "kind": "spell_off",
     "pair": "spell", "role": "stop",
     "triggers": ["stop spell mode", "spell mode stop", "end spell", "end spelling",
                  "stop spelling", "stop spell", "end letters", "normal mode",
                  "fine compitazione", "fine lettere", "modo normale", "basta lettere"]},

    # ── editing the un-submitted line (only works until Enter is pressed) ─────
    # DELETE pair: "start delete mode" <words> "stop delete mode" removes the first
    # occurrence of <words> found to the LEFT of the cursor (the last typed one).
    {"group": "editing", "label": "START DELETE MODE", "kind": "delete_start",
     "pair": "delete", "role": "start",
     "triggers": ["start delete mode", "delete mode", "inizia modo cancella", "modo cancella"]},
    {"group": "editing", "label": "STOP DELETE MODE", "kind": "delete_stop",
     "pair": "delete", "role": "stop",
     "triggers": ["stop delete mode", "end delete mode", "ferma modo cancella",
                  "fine modo cancella"]},
    # REPLACE: "start replace mode" <find> "replace with" <new> "stop replace mode".
    {"group": "editing", "label": "START REPLACE MODE", "kind": "replace_start",
     "pair": "replace", "role": "start",
     "triggers": ["start replace mode", "replace mode", "inizia modo sostituzione",
                  "modo sostituzione"]},
    {"group": "editing", "label": "REPLACE WITH", "kind": "replace_with",
     "pair": "replace", "role": "with",
     "triggers": ["replace with", "sostituisci con"]},
    {"group": "editing", "label": "STOP REPLACE MODE", "kind": "replace_stop",
     "pair": "replace", "role": "stop",
     "triggers": ["stop replace mode", "end replace mode", "ferma modo sostituzione",
                  "fine modo sostituzione"]},
    # UNDO / REDO the last word, deletion or replacement.
    {"group": "editing", "label": "undo", "kind": "undo",
     "triggers": ["undo", "annulla"]},
    {"group": "editing", "label": "redo", "kind": "redo",
     "triggers": ["redo", "rifai", "ripeti"]},
]

# Edit-command kinds whose phrase must still be recognised WHILE capturing a
# delete/replace target (everything else spoken in that window is literal text).
_EDIT_CMDS = {"delete_stop", "replace_with", "replace_stop"}


def _splice(line: str, idx: int, length: int, insert: str) -> str:
    """Remove `length` chars at `idx` and insert `insert`, tidying word spacing."""
    left = line[:idx].rstrip()
    right = line[idx + length:].lstrip()
    return " ".join(p for p in (left, insert.strip(), right) if p)

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


def interpret(transcript: str, modes: dict | None = None) -> list[tuple[str, str]]:
    # `modes` carries persistent state ACROSS utterances: spelling + case, AND the
    # editable line buffer (`line`) with its undo/redo stacks and any in-progress
    # delete/replace capture. Pass a dict (mutated in place) to keep all of that
    # between sentences; pass nothing for a one-shot interpret (tests pass a dict
    # explicitly when they need persistence).
    if modes is None:
        modes = {}
    tokens = transcript.split()
    n = len(tokens)
    actions: list[tuple[str, str]] = []
    buf: list[tuple[str, bool]] = []  # (text, glue_before)
    next_glue = False
    case_mode = modes.get("case_mode", "none")  # persists across utterances
    cap_once = False
    literal_once = False
    pending_close: str | None = None
    spelling = modes.get("spelling", False)  # persists across utterances

    # ── editable-line state (persists until Enter is pressed) ────────────────
    line = modes.get("line", "")            # exact on-screen text since last Enter
    undo: list[str] = modes.get("undo", [])  # prior line states (newest last)
    redo: list[str] = modes.get("redo", [])
    edit_mode = modes.get("edit_mode")      # None | delete | replace_find | replace_with
    target: list[str] = modes.get("edit_target", [])  # captured find words
    repl: list[str] = modes.get("edit_repl", [])      # captured replacement words

    def flush():
        nonlocal buf, line
        if buf:
            s = buf[0][0]
            for piece, glue in buf[1:]:
                s += ("" if glue else " ") + piece
            actions.append(("type", s))
            undo.append(line)
            redo.clear()
            line += s
            buf = []

    def apply_line(new_line: str):
        # Rewrite the on-screen line: erase the whole thing, retype the new content.
        nonlocal line
        if new_line == line:
            return
        if line:
            actions.append(("erase", str(len(line))))
        if new_line:
            actions.append(("type", new_line))
        line = new_line

    def do_delete(phrase: str):
        if not phrase:
            return
        idx = line.rfind(phrase)  # LEFT of cursor = last occurrence
        if idx == -1:
            return
        undo.append(line)
        redo.clear()
        apply_line(_splice(line, idx, len(phrase), ""))

    def do_replace(find: str, with_text: str):
        if not find:
            return
        idx = line.rfind(find)
        if idx == -1:
            return
        undo.append(line)
        redo.clear()
        apply_line(_splice(line, idx, len(find), with_text))

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
        # ── delete/replace capture: collect literal target/replacement words ──
        if edit_mode is not None:
            cmd = None
            clen = 0
            for w in range(min(_MAXW, n - i), 0, -1):
                phrase = " ".join(_norm(t) for t in tokens[i:i + w])
                r = _PHRASES.get(phrase)
                if r and r["kind"] in _EDIT_CMDS:
                    cmd, clen = r, w
                    break
            if cmd is not None:
                k = cmd["kind"]
                if edit_mode == "delete" and k == "delete_stop":
                    do_delete(" ".join(target))
                    edit_mode, target = None, []
                    i += clen
                    continue
                if edit_mode == "replace_find" and k == "replace_with":
                    edit_mode, repl = "replace_with", []
                    i += clen
                    continue
                if edit_mode in ("replace_find", "replace_with") and k == "replace_stop":
                    do_replace(" ".join(target), " ".join(repl))
                    edit_mode, target, repl = None, [], []
                    i += clen
                    continue
            # otherwise the token is a literal word of the target / replacement
            (repl if edit_mode == "replace_with" else target).append(tokens[i])
            i += 1
            continue

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
            if matched["key"] == "Enter":
                # Sentence submitted — it's no longer editable. Reset the line state.
                line, edit_mode, target, repl = "", None, [], []
                undo.clear()
                redo.clear()
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
        elif kind == "delete_start":
            flush()
            edit_mode, target = "delete", []
        elif kind == "replace_start":
            flush()
            edit_mode, target, repl = "replace_find", [], []
        elif kind == "undo":
            flush()
            if undo:
                redo.append(line)
                apply_line(undo.pop())
        elif kind == "redo":
            flush()
            if redo:
                undo.append(line)
                apply_line(redo.pop())
        # delete_stop / replace_with / replace_stop outside a capture are no-ops.

    flush()
    modes["spelling"] = spelling
    modes["case_mode"] = case_mode
    modes["line"] = line
    modes["undo"] = undo
    modes["redo"] = redo
    modes["edit_mode"] = edit_mode
    modes["edit_target"] = target
    modes["edit_repl"] = repl
    return actions


def render(actions: list[tuple[str, str]]) -> str:
    """Human-readable preview of what will be typed (keys shown as ⟨Key⟩, an
    erase of N chars as ⌫N)."""
    out = []
    for kind, val in actions:
        if kind == "type":
            out.append(val)
        elif kind == "erase":
            out.append(f"⌫{val}")
        else:
            out.append(f"⟨{val}⟩")
    return "".join(out)


# Canned phrases Whisper emits on silence/noise (YouTube-style). The server's
# no_speech_prob gate catches most silence; this is the belt-and-braces text
# filter for the ones that slip through. Single common words are NOT listed (so
# a legitimate one-word utterance isn't dropped).
_HALLUCINATIONS = {
    "thank you", "thank you very much", "thanks for watching",
    "thank you for watching", "please subscribe", "like and subscribe",
    "subscribe to my channel", "see you next time", "see you in the next video",
    "grazie", "grazie mille", "grazie per la visione", "iscriviti al canale",
}


def looks_like_hallucination(text: str) -> bool:
    """True if `text` looks like a Whisper silence/noise hallucination — empty,
    pure punctuation/music, or one of the canned phrases."""
    t = text.strip().lower().strip(" .,!?-—…\"'♪~")
    if not t:
        return True
    if all(not c.isalnum() for c in t):  # punctuation / music notes only
        return True
    return t in _HALLUCINATIONS


_KEY_GLYPH = {"Enter": "⏎", "Tab": "⇥", "Escape": "esc", "BSpace": "⌫",
              "Newline": "⇧⏎", "Up": "↑", "Down": "↓"}


def _rule_out(r: dict) -> str:
    """Short literal 'what it types' for a rule (the blue chip in the app)."""
    kind = r["kind"]
    if kind == "char":
        return r["char"]
    if kind == "fence":
        return "```"
    if kind == "prefix":
        return r["text"].strip()
    if kind == "wrap":
        return f'{r["open"]}…{r["close"]}'
    if kind == "key":
        return str(_KEY_GLYPH.get(r["key"], r["key"]))
    if kind == "case":
        # "none" is CAPS STOP — show abc (back to normal text), not a dash.
        return {"upper": "ABC", "lower": "abc", "none": "abc"}.get(r["mode"], "")
    if kind == "case_once":
        return "Aa"
    if kind == "literal":
        return "as-is"
    if kind == "spell_on":
        return "a·b·c"
    if kind == "spell_off":
        return "→ words"
    if kind == "glue":
        return "no␣"
    if kind == "delete_start":
        return "✂"
    if kind == "delete_stop":
        return "✂ ✓"
    if kind == "replace_start":
        return "⇄"
    if kind == "replace_with":
        return "→"
    if kind == "replace_stop":
        return "⇄ ✓"
    if kind == "undo":
        return "⎌"
    if kind == "redo":
        return "↻"
    return str(r.get("label", ""))


# Italian display phrase per command, keyed by the English say (triggers[0]). Used
# only for the app's IT/EN chip toggle — all of these are also live voice triggers.
# Commands absent here keep their English phrase in Italian mode too (tab, slash,
# backslash, backtick, escape — Italians say those in English).
IT_SAY = {
    "enter": "invio",
    "new line": "a capo",
    "backspace": "cancella",
    "arrow up": "freccia su",
    "arrow down": "freccia giù",
    "dot": "punto",
    "comma": "virgola",
    "dash": "trattino",
    "underscore": "trattino basso",
    "no space": "senza spazio",
    "at sign": "chiocciola",
    "hash": "cancelletto",
    "dollar": "dollaro",
    "percent": "percento",
    "caret": "accento circonflesso",
    "ampersand": "e commerciale",
    "star": "asterisco",
    "pipe": "barra verticale",
    "plus": "più",
    "equals": "uguale",
    "colon": "due punti",
    "semicolon": "punto e virgola",
    "question mark": "punto interrogativo",
    "bang": "punto esclamativo",
    "less than": "minore",
    "greater than": "maggiore",
    "open quotes": "virgolette aperte",
    "close quotes": "virgolette chiuse",
    "apostrophe": "apostrofo",
    "open code block": "blocco di codice",
    "close code block": "chiudi blocco",
    "open parentheses": "parentesi tonda aperta",
    "close parentheses": "parentesi tonda chiusa",
    "open square brackets": "parentesi quadra aperta",
    "close square brackets": "parentesi quadra chiusa",
    "open curly braces": "parentesi graffa aperta",
    "close curly braces": "parentesi graffa chiusa",
    "start caps mode": "modo maiuscolo",
    "stop caps mode": "modo normale",
    "lowercase": "minuscolo",
    "capital": "maiuscola",
    "heading": "titolo",
    "heading two": "sottotitolo",
    "heading three": "sotto sottotitolo",
    "bullet": "punto elenco",
    "numbered item": "elenco numerato",
    "quote block": "citazione",
    "bold": "grassetto",
    "italic": "corsivo",
    "strikethrough": "barrato",
    "horizontal rule": "linea orizzontale",
    "literal": "letterale",
    "start spell mode": "compitazione",
    "stop spell mode": "fine compitazione",
    "start delete mode": "modo cancella",
    "stop delete mode": "fine cancella",
    "start replace mode": "modo sostituzione",
    "replace with": "sostituisci con",
    "stop replace mode": "fine sostituzione",
    "undo": "annulla",
    "redo": "rifai",
}


def cheatsheet() -> list[dict]:
    """Grouped rules for the app: [{group, items:[{say, say_it, out, label, triggers}]}]."""
    groups: dict[str, list[dict]] = {}
    for r in RULES:
        say = r["triggers"][0]
        groups.setdefault(r["group"], []).append(
            {
                "say": say,
                "say_it": IT_SAY.get(say, say),  # Italian phrase, English fallback
                "out": _rule_out(r),
                "label": r["label"],
                "triggers": r["triggers"],
                # START/STOP pairing so the app draws them as one two-row cell.
                "pair": r.get("pair"),
                "role": r.get("role"),
            }
        )
    return [{"group": g, "items": items} for g, items in groups.items()]


if __name__ == "__main__":
    for t in [
        "slash context",
        "tilde slash Code slash my dash project slash",
        "barra context",
        "git status invio",
        "open parentheses foo close parentheses",
        "tra parentesi ciao",
        "all caps deploy now caps off please",
        "maiuscolo errore minuscolo",
        "make a code block python new line print hello",
        "due punti punto e virgola",
        "literal slash is a word",
    ]:
        print(f"{t!r}\n   -> {render(interpret(t))!r}\n")
