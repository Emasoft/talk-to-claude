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
    {"group": "keys", "label": "␣ space", "kind": "char", "char": " ",
     "triggers": ["space", "spacebar", "space bar", "spazio"]},

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
    # "backword <N>" deletes N whole words back (with the spaces between them).
    {"group": "editing", "label": "⌫ word(s)", "kind": "backword",
     "triggers": ["backword", "backwords", "backward", "backwards", "back word"]},
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
# Kinds that still ACT inside spelling: end-spell, keys (Enter/Tab/…), case toggles,
# and punctuation symbols ("dot"→"." while spelling "u dot es" → "U.S"). Everything
# else becomes a letter via SPELL_MAP.
_SPELL_OK = {"spell_off", "key", "case", "case_once", "char"}
_SPACE_WORDS = {"space", "spazio", "spacebar"}

# Spoken letter names -> letters (English + Italian + common ASR mishearings).
# Whisper transcribes spelled letters by their phonetic names ("L M R" -> "al em
# er"); this maps them back. Unknown tokens pass through unchanged (so an
# already-merged "cat" stays "cat").
SPELL_MAP = {
    "a": "a", "ay": "a", "eh": "a", "ae": "a",
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
    "m": "m", "em": "m", "am": "m", "emme": "m",
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

# ── prefix mode (optional, toggled per-connection by the app) ────────────────
# When enabled, dictation is LITERAL by default and NOTHING fires without the prefix
# word ("command" / "comando") — not even space. The grammar is a NESTED SCOPE STACK
# where START = "(" and STOP = ")", and COMMAND takes exactly ONE argument:
#   • single:  "command <cmd>"                       → fires exactly one command, then literal
#   • mode unit (= one argument): "command <MODE> start … <MODE> stop"
#         "command number start four five number stop"        → 45
#         nesting is still one argument: CAPS(SPELL(…)) →
#         "command caps start spell start al em er spell stop caps stop" → LMR
#   • region (many arguments): "command start <blocks…> command stop"
#         "command start number start one number stop caps start spell start al em er
#          spell stop caps stop command stop"                  → 1LMR
#   • repeat:  "<cmd> <N> times"                      → repeat — REGION-only
#   • words:   "command backword <N>"                → delete N whole words back
# STOP pops the innermost open mode (LIFO). A bare STOP with nothing open is literal.
# The prefix only "arms" when a real command follows it, so "run this command" still
# prints literally (the lookahead gate).
_PREFIX_WORDS = {"command", "commande", "commando", "commands", "comando", "comandi"}
_START_WORDS = {"start", "begin", "inizio", "inizia"}
_STOP_WORDS = {"stop", "end", "fine", "ferma", "basta", "termina"}
# When the ASR splits the trigger across a pause it emits the tail of "command"
# as its own little utterance ("command" → "command" + "come and"). If such an
# utterance lands right after a provisional "command", it's NOT real text — it's
# the trigger's tail. We swallow it and keep the prefix armed for the next word.
_PREFIX_FILLER = {"come", "and", "on", "commander"}
_TIMES_WORDS = {"times", "time", "volte", "volta"}

# Modes that form a self-contained "command <MODE> start … <MODE> stop" unit: the
# words inside need no prefix and the closing "<MODE> stop" needs no "command".
_MODE_WORDS = {
    "caps": "caps", "capital": "caps", "capitals": "caps", "uppercase": "caps",
    "maiuscolo": "caps", "maiuscole": "caps",
    "spell": "spell", "spelling": "spell", "compita": "spell", "compitazione": "spell",
    "number": "number", "numbers": "number", "numero": "number", "numeri": "number",
    "delete": "delete", "cancella": "delete",
    "replace": "replace", "sostituzione": "replace", "sostituisci": "replace",
    # List modes: each "command enter" inside makes a new row; nesting indents one
    # level. bullet = "- " markers; bulletnum = "1." / nested "2.1." numbering.
    "bullet": "bullet", "bullets": "bullet",
    "bulletnum": "bulletnum", "ordered": "bulletnum", "numbered": "bulletnum",
}
# The poppable modes. caps is an ambient MODIFIER (uppercases) that nests over a
# content mode; spell/number/delete/replace decide what a content word becomes;
# bullet/bulletnum drive auto-indented list rows. A "<MODE> stop" pops whichever
# of these is innermost in the scope stack.
_MODE_TAGS = {"caps", "spell", "number", "delete", "replace", "bullet", "bulletnum"}
_LIST_TAGS = {"bullet", "bulletnum"}
_LIST_INDENT = "    "  # 4 spaces per nesting level

# Words that, when an utterance OPENS with them right after a thinking pause,
# signal a continuation of the previous fragment rather than a new sentence — so
# we strip the pause-punctuation Whisper guessed and lowercase the opener, merging
# the two into one flowing sentence. Single-letter words are excluded on purpose
# (English "I" / "a" and Italian "e"/"o"/"i" are too ambiguous to de-capitalize).
_CONTINUATION_WORDS = {
    # English: articles, conjunctions, prepositions, relatives/connectors
    "the", "an", "and", "but", "or", "nor", "so", "yet", "because", "although",
    "though", "while", "if", "unless", "since", "whether", "as", "with", "without",
    "of", "to", "for", "from", "in", "into", "on", "onto", "at", "by", "about",
    "over", "under", "after", "before", "between", "through", "during", "against",
    "than", "that", "which", "who", "whom", "whose", "where", "when", "then", "plus",
    # Italian counterparts (single-letter ones omitted)
    "il", "lo", "la", "gli", "le", "un", "una", "uno", "ed", "ma", "perche", "che",
    "con", "senza", "di", "da", "per", "tra", "fra", "su", "del", "della", "dei",
    "delle", "quando", "dove", "come", "mentre",
}

_NUM_ONES = {
    "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
    "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
    "seventeen": 17, "eighteen": 18, "nineteen": 19,
    "uno": 1, "due": 2, "tre": 3, "quattro": 4, "cinque": 5, "sei": 6, "sette": 7,
    "otto": 8, "nove": 9, "dieci": 10, "undici": 11, "dodici": 12, "tredici": 13,
    "quattordici": 14, "quindici": 15, "sedici": 16,
}
_NUM_TENS = {
    "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    "seventy": 70, "eighty": 80, "ninety": 90,
    "venti": 20, "trenta": 30, "quaranta": 40, "cinquanta": 50,
}


def _command_follows(tokens: list[str], j: int) -> bool:
    """True if a known command phrase starts at tokens[j] — the prefix-arm lookahead."""
    m = len(tokens)
    for w in range(min(_MAXW, m - j), 0, -1):
        if " ".join(_norm(t) for t in tokens[j:j + w]) in _PHRASES:
            return True
    return False


def _prefix_would_act(tokens: list[str]) -> bool:
    """True if prepending 'command' to this utterance would fire a command or open a
    scope — used for RETROACTIVE cross-utterance correction. When a lone 'command'
    was written provisionally in the previous utterance and THIS one starts with a
    command word ('enter'), a 'start'/'stop', or a '<mode> start/stop', we delete the
    provisional word and reinterpret as 'command <this utterance>'. The STOP case
    matters because the VAD also splits the CLOSING 'command stop' into two
    utterances ('command' then 'stop')."""
    if not tokens:
        return False
    a = _norm(tokens[0])
    b = _norm(tokens[1]) if len(tokens) > 1 else ""
    if a in _START_WORDS or a in _STOP_WORDS:            # "command" | "start …" / "stop"
        return True
    if a in _MODE_WORDS and (b in _START_WORDS or b in _STOP_WORDS):  # "command" | "number start/stop"
        return True
    return _command_follows(tokens, 0)                   # "command" | "enter"


def _all_filler(tokens: list[str]) -> bool:
    """True if a SHORT utterance is nothing but trigger-tail filler — what the ASR
    emits when it splits 'command' into 'command' + 'come and'. Bounded to ≤3 tokens
    so it never eats a real sentence."""
    return bool(tokens) and len(tokens) <= 3 and all(_norm(t) in _PREFIX_FILLER for t in tokens)


def _num_value(tok: str) -> int | None:
    """Single token → its numeric value (digit or number word), else None."""
    if tok.isdigit():
        return int(tok)
    if tok in _NUM_TENS:
        return _NUM_TENS[tok]
    return _NUM_ONES.get(tok)


def _parse_count(tokens: list[str], i: int) -> tuple[int | None, int]:
    """Parse a count at tokens[i] — a digit, a number word, or a 'twenty five'
    compound. Returns (value, tokens_consumed) or (None, 0)."""
    if i >= len(tokens):
        return None, 0
    t0 = _norm(tokens[i])
    if t0 in _NUM_TENS:
        t1 = _norm(tokens[i + 1]) if i + 1 < len(tokens) else ""
        if t1 in _NUM_ONES and _NUM_ONES[t1] < 10:
            return _NUM_TENS[t0] + _NUM_ONES[t1], 2
        return _NUM_TENS[t0], 1
    v = _num_value(t0)
    return (v, 1) if v is not None else (None, 0)


def interpret(transcript: str, modes: dict | None = None,
              prefix_mode: bool = False) -> list[tuple[str, str]]:
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
    need_sep = False  # prepend a space before this utterance's first word (set below)
    case_mode = modes.get("case_mode", "none")  # persists across utterances
    cap_once = False
    literal_once = False
    pending_close: str | None = None
    spelling = modes.get("spelling", False)  # persists across utterances
    num_region = modes.get("num_region", False)  # "command number start … number stop"
    # prefix-mode nested scopes (persists across utterances). Frames:
    #   'cmd'  — a "command start … command stop" region (many arguments)
    #   'once' — a single-argument COMMAND, auto-popped when its one block completes
    #   <mode> — caps | spell | number | delete | replace  (a START…STOP block)
    stack: list[str] = list(modes.get("scope_stack", []))
    # Open list frames (one per nested bullet/bulletnum), innermost last. Each:
    #   {"type": "bullet"|"bulletnum", "count": <items so far>, "prefix": "<parent num>"}
    # pending_item = a new row is queued; its marker is emitted when content arrives
    # (lazy, so a nested "<list> start" between rows can change the indent first).
    bullets: list[dict] = [dict(f) for f in modes.get("bullets", [])]
    pending_item = bool(modes.get("pending_item", False))

    # ── editable-line state (persists until Enter is pressed) ────────────────
    line = modes.get("line", "")            # exact on-screen text since last Enter
    undo: list[str] = modes.get("undo", [])  # prior line states (newest last)
    redo: list[str] = modes.get("redo", [])
    edit_mode = modes.get("edit_mode")      # None | delete | replace_find | replace_with
    target: list[str] = modes.get("edit_target", [])  # captured find words
    repl: list[str] = modes.get("edit_repl", [])      # captured replacement words

    # ── retroactive cross-utterance prefix correction ────────────────────────
    # A previous lone "command" utterance wrote itself PROVISIONALLY (after a pause
    # we couldn't yet know a command word would follow). If THIS utterance opens
    # with a command or a scope, erase that provisional word now and reinterpret
    # the whole utterance as "command <this utterance>". armed_prefix/_baseline are
    # set later if THIS utterance turns out to be a lone "command".
    armed_prefix = False
    armed_baseline = 0
    retro_fired = False
    armed_erase = int(modes.pop("armed_prefix_erase", 0))   # read + clear (one-shot)
    pending_mode = modes.pop("pending_mode", None)          # "command <mode>" awaiting its "start"
    if prefix_mode and armed_erase:
        a0 = _norm(tokens[0]) if tokens else ""
        if pending_mode:
            # The previous utterance ended with "command <mode>" with no "start" yet (the VAD
            # split "command caps" | "start …"). If THIS one opens with start/stop, erase the
            # provisional "command <mode>" and reinterpret the full "command <mode> start/stop …".
            if a0 in _START_WORDS or a0 in _STOP_WORDS:
                if line and armed_erase <= len(line):
                    actions.append(("erase", str(armed_erase)))
                    undo.append(line)
                    redo.clear()
                    line = line[: len(line) - armed_erase]
                tokens = ["command", pending_mode] + tokens
                n = len(tokens)
                retro_fired = True
            elif _all_filler(tokens):
                modes["armed_prefix_erase"] = armed_erase
                modes["pending_mode"] = pending_mode   # keep the pending mode alive through filler
                return []
            # else: "command <mode>" was literal after all — drop it, type this normally.
        elif _prefix_would_act(tokens):
            if line and armed_erase <= len(line):
                actions.append(("erase", str(armed_erase)))
                undo.append(line)
                redo.clear()
                line = line[: len(line) - armed_erase]
            tokens = ["command"] + tokens      # re-arm as if "command" preceded this utterance
            n = len(tokens)
            retro_fired = True
        elif _all_filler(tokens):
            # The ASR split the trigger ("command" + "come and"): swallow the tail and
            # KEEP the arm so the NEXT utterance's start/command still completes it.
            # Nothing typed, provisional "command" stays on screen, arm survives.
            modes["armed_prefix_erase"] = armed_erase
            return []
        # else: a non-acting, non-filler utterance — the provisional "command" was a
        # real literal word after all; drop the arm and let this utterance type normally.

    # ── continuation merge (natural dictation across a thinking pause) ────────
    # When this utterance continues a non-submitted line, the previous fragment
    # often carries pause-punctuation Whisper guessed (. ? ! ,) and this one opens
    # capitalized as if a new sentence. If it opens with a CONTINUATION word
    # (the/with/and/that/…) we treat the pause as mid-thought: strip that dangling
    # punctuation and lowercase the opener so the fragments flow as one sentence.
    # The separating space itself is added by flush() for EVERY continuation.
    if line and tokens and not retro_fired and _norm(tokens[0]) in _CONTINUATION_WORDS \
            and line[-1:] in (".", "?", "!", ","):
        actions.append(("erase", "1"))
        undo.append(line)
        redo.clear()
        line = line[:-1]
        w0 = tokens[0]
        tokens = [w0[:1].lower() + w0[1:], *tokens[1:]]
    # Separate this utterance from a non-submitted previous line with a space.
    need_sep = bool(line) and not line.endswith(" ")

    def flush():
        nonlocal buf, line, need_sep
        if buf:
            first_glue = buf[0][1]
            s = buf[0][0]
            for piece, glue in buf[1:]:
                s += ("" if glue else " ") + piece
            # Separate from the previous (non-submitted) line with a space — but not
            # before hugging punctuation (a leading "," / ")" stays glued).
            if need_sep and not first_glue and s and not s[0].isspace():
                s = " " + s
            need_sep = False
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

    def do_backword(n_words: int):
        # Delete the last n_words whole words (and the spaces among them) from the
        # editable line, keeping the boundary space that precedes the deleted run.
        nonlocal line
        flush()                       # commit any pending typed text so `line` is current
        if not line or n_words <= 0:
            return
        end = len(line)
        for _ in range(n_words):
            j = end
            while j > 0 and line[j - 1] == " ":   # skip spaces left of the word
                j -= 1
            while j > 0 and line[j - 1] != " ":    # skip the word itself
                j -= 1
            end = j
        cut = len(line) - end
        if cut > 0:
            undo.append(line)
            redo.clear()
            actions.append(("erase", str(cut)))
            line = line[:end]

    # ── prefix-mode scope stack: START pushes a frame, STOP pops the innermost ──
    def _mode_open() -> bool:
        return any(t in _MODE_TAGS for t in stack)

    def push_mode(tag: str):
        stack.append(tag)
        enter_mode(tag)

    def close_once():
        # a single-argument COMMAND closes the moment its one block finishes
        while stack and stack[-1] == "once":
            stack.pop()

    def pop_mode():
        # Pop the innermost open mode; reset its flat state (or fire delete/replace);
        # then auto-close a single-arg COMMAND now exposed. Back at the literal level,
        # break the glue so following prose spaces normally (siblings inside a region
        # keep gluing, because there the stack is NOT yet empty).
        nonlocal next_glue
        idx = next((k for k in range(len(stack) - 1, -1, -1) if stack[k] in _MODE_TAGS), None)
        if idx is None:
            return
        tag = stack.pop(idx)
        if not (tag in ("caps", "spell", "number") and tag in stack):
            exit_mode(tag)        # a deeper frame of the same ambient mode keeps it on
        close_once()
        if not stack:
            next_glue = False

    def close_region():
        # "command stop": unwind any nested modes, then the nearest 'cmd' region frame.
        nonlocal next_glue
        while stack and stack[-1] != "cmd":
            pop_mode() if stack[-1] in _MODE_TAGS else stack.pop()
        if stack and stack[-1] == "cmd":
            stack.pop()
        close_once()
        if not stack:
            next_glue = False

    def enter_mode(tag: str):
        nonlocal case_mode, spelling, num_region, edit_mode, target, repl, pending_item
        if tag == "caps":
            case_mode = "upper"
        elif tag == "spell":
            spelling = True
        elif tag == "number":
            num_region = True
        elif tag == "delete":
            flush()
            edit_mode, target = "delete", []
        elif tag == "replace":
            flush()
            edit_mode, target, repl = "replace_find", [], []
        elif tag in _LIST_TAGS:
            # A bulletnum nested in a bulletnum inherits the parent's CURRENT number as
            # its prefix (parent item 2 -> children 2.1, 2.2); otherwise it restarts at 1.
            parent = bullets[-1] if bullets else None
            if tag == "bulletnum" and parent and parent["type"] == "bulletnum":
                prefix = (parent["prefix"] + "." if parent["prefix"] else "") + str(parent["count"])
            else:
                prefix = ""
            bullets.append({"type": tag, "count": 0, "prefix": prefix})
            pending_item = True

    def exit_mode(tag: str):
        nonlocal case_mode, spelling, num_region, edit_mode, target, repl, pending_item
        if tag == "caps":
            case_mode = "none"
        elif tag == "spell":
            spelling = False
        elif tag == "number":
            num_region = False
        elif tag == "delete":
            do_delete(" ".join(target))
            edit_mode, target = None, []
        elif tag == "replace":
            do_replace(" ".join(target), " ".join(repl))
            edit_mode, target, repl = None, [], []
        elif tag in _LIST_TAGS:
            if bullets:
                bullets.pop()
            pending_item = bool(bullets)  # continue the parent list, or end the list

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

    def maybe_list_marker():
        # Lazily emit the next row's marker (a newline if needed, the indent, then the
        # "- " / "N. " marker) the MOMENT real content arrives — so a "<list> start"
        # between rows can deepen the indent first, and a trailing "command enter" right
        # before STOP never leaves an empty row.
        nonlocal pending_item, line, next_glue, need_sep
        if not (bullets and pending_item):
            return
        pending_item = False
        flush()                                   # commit any queued text to `line` first
        fr = bullets[-1]
        marker = "" if (not line or line.endswith("\n")) else "\n"
        marker += _LIST_INDENT * (len(bullets) - 1)
        if fr["type"] == "bulletnum":
            fr["count"] += 1
            num = (fr["prefix"] + "." if fr["prefix"] else "") + str(fr["count"])
            marker += num + ". "
        else:
            marker += "- "
        actions.append(("type", marker))
        undo.append(line)
        redo.clear()
        line += marker
        need_sep = False                          # the marker controls spacing, not flush()
        next_glue = True                          # the content word attaches to the marker

    def emit_symbol(ch: str):
        nonlocal next_glue
        maybe_list_marker()
        buf.append((ch, True))
        next_glue = ch not in _CLOSERS

    def emit_word(w: str):
        nonlocal next_glue, pending_close
        maybe_list_marker()
        buf.append((style(w), next_glue))
        next_glue = False
        if pending_close is not None:
            buf.append((pending_close, True))
            next_glue = False  # a wrapped group is complete — space before the next word
            pending_close = None

    def emit_letter(ch: str):
        nonlocal next_glue, cap_once
        maybe_list_marker()
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
        # ── prefix mode: literal by default; NOTHING fires without the "command" prefix
        #    Single   : "command <cmd>"
        #    Region   : "command start … command stop"   (loose commands; <N> times here)
        #    Mode unit: "command <MODE> start … <MODE> stop"  (no prefix inside; bare stop)
        if prefix_mode:
            ptok = _norm(tokens[i])
            nxt = _norm(tokens[i + 1]) if i + 1 < n else ""
            nxt2 = _norm(tokens[i + 2]) if i + 2 < n else ""
            # A. Inside an open scope, "<MODE> start" enters a NESTED mode (no prefix).
            if stack and ptok in _MODE_WORDS and nxt in _START_WORDS:
                push_mode(_MODE_WORDS[ptok])
                i += 2
                continue
            # B. "<MODE> stop" / bare "stop" pops the innermost open mode (LIFO). With
            #    nothing open, a bare "stop" is literal text (handled by D/F below).
            if ptok in _MODE_WORDS and nxt in _STOP_WORDS and _mode_open():
                pop_mode()
                i += 2
                continue
            if ptok in _STOP_WORDS and _mode_open():
                pop_mode()
                i += 1
                continue
            # C. The "command" prefix opens a new argument (or is literal via the gate).
            if ptok in _PREFIX_WORDS:
                if nxt in _START_WORDS:                          # "command start" → region (many args)
                    stack.append("cmd")
                    i += 2
                    continue
                if nxt in _STOP_WORDS:                           # "command stop" → close the region
                    close_region()
                    i += 2
                    continue
                if nxt in _MODE_WORDS and nxt2 in _START_WORDS:  # "command <MODE> start" = COMMAND(MODE(…))
                    stack.append("once")
                    push_mode(_MODE_WORDS[nxt])
                    i += 3
                    continue
                if nxt in _MODE_WORDS and i + 2 >= n:            # "command <MODE>" at utterance END →
                    armed_baseline = len(line)                  # arm a pending mode-open; the NEXT
                    emit_word(tokens[i])                        # utterance's "start" reconstructs the
                    emit_word(tokens[i + 1])                    # full "command <mode> start" (VAD split
                    armed_prefix = True                         # "command caps" | "start …"). Provisional.
                    modes["pending_mode"] = _MODE_WORDS[nxt]
                    i += 2
                    continue
                if _command_follows(tokens, i + 1):              # "command <cmd>" = COMMAND(cmd), one arg
                    stack.append("once")
                    i += 1                          # fall through to fire ONE command; close_once() after
                elif n == 1:                        # a LONE "command" utterance writes "command"
                    emit_word(tokens[i])            # PROVISIONALLY and arms a retro-erase: if the NEXT
                    armed_prefix = True             # utterance starts with a command, we delete this word
                    armed_baseline = len(line)      # and run it instead (handles a pause splitting
                    i += 1                          # "command" from its command word into two utterances)
                    continue
                else:
                    emit_word(tokens[i])            # lookahead gate: bare "command" mid-text is literal
                    i += 1
                    continue
            # D. Inside the NUMBER block: spoken numbers → concatenated digits.
            elif num_region and edit_mode is None:
                v = _num_value(ptok)
                if v is not None:
                    buf.append((str(v), next_glue))
                    next_glue = True
                else:
                    emit_word(tokens[i])            # a non-number inside the block stays literal
                i += 1
                continue
            # E. A delete/replace/spell block is open → words inside take no prefix; fall
            #    through to the capture / spelling handlers below.
            elif edit_mode is not None or spelling:
                pass
            # F. Inside a generic command region/once → command-by-default; else literal.
            elif stack:
                pass
            else:
                emit_word(tokens[i])
                i += 1
                continue

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

        # "backword <N>" — delete N whole words from the end of the editable line.
        if matched["kind"] == "backword":
            cnt, cons = _parse_count(tokens, i + mlen)
            do_backword(cnt if cnt is not None else 1)
            i += mlen + (cons if cnt is not None else 0)
            if prefix_mode:
                close_once()          # a single-arg "command backword <N>" ends here
            continue

        # "<command> <N> times" repeats — ONLY inside a "command start … command stop"
        # region (a 'cmd' frame). In single form the trailing "<N> times" stays literal
        # text (by design, so "command backspace twelve times" is ⌫ then "twelve times").
        rep = 1
        if "cmd" in stack:
            cnt, cons = _parse_count(tokens, i + mlen)
            if cnt is not None and i + mlen + cons < n and _norm(tokens[i + mlen + cons]) in _TIMES_WORDS:
                rep = max(1, min(cnt, 1000))
                mlen += cons + 1

        i += mlen
        kind = matched["kind"]
        if kind == "spell_on":
            spelling = True
        elif kind == "spell_off":
            spelling = False
        elif kind == "char":
            for _ in range(rep):
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
            key = matched["key"]
            if bullets and key in ("Enter", "Newline"):
                # Inside a list, "command enter" = NEXT ROW (a soft newline), never a
                # submit. The row's marker is emitted lazily when its content arrives.
                pending_item = True
            elif key == "BSpace" and line:
                # N backspaces == erase N chars; also keep the line buffer in sync so a
                # following backword / delete still lines up with what's on screen.
                cut = min(rep, len(line))
                undo.append(line)
                redo.clear()
                actions.append(("erase", str(cut)))
                line = line[: len(line) - cut]
            else:
                for _ in range(rep):
                    actions.append(("key", key))
                if key == "Enter":
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

        # A single-argument COMMAND (e.g. "command slash") fires exactly one command,
        # then its 'once' frame closes so everything after is literal again.
        if prefix_mode:
            close_once()

    flush()
    # If this utterance was a lone "command", remember how many chars it wrote so the
    # NEXT utterance can retroactively erase them (see the block at the top).
    if armed_prefix and len(line) > armed_baseline:
        modes["armed_prefix_erase"] = len(line) - armed_baseline
    modes["spelling"] = spelling
    modes["scope_stack"] = stack
    modes["sym_mode"] = bool(stack)   # app "symbols" indicator: any command scope open
    modes["num_region"] = num_region
    modes["bullets"] = bullets        # open list frames (persist across utterances)
    modes["pending_item"] = pending_item
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
