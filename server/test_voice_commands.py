"""Tests for the bilingual verbal-command interpreter. Run: python server/test_voice_commands.py"""

from voice_commands import interpret, looks_like_hallucination, render

# (description, spoken transcript, expected rendered output)
CASES = [
    ("slash command", "slash context", "/context"),
    ("path with dashes", "tilde slash Code slash my dash project slash", "~/Code/my-project/"),
    ("barra is pipe (IT)", "ls barra grep foo", "ls|grep foo"),
    ("barra rovesciata = backslash", "barra rovesciata n", "\\n"),
    ("shift-invio newline (hyphen)", "uno shift-invio due", "uno⟨Newline⟩due"),
    ("italian enter (invio)", "git status invio", "git status⟨Enter⟩"),
    ("english enter", "run the tests submit", "run the tests⟨Enter⟩"),
    ("arrow keys (menu/history nav)", "arrow up arrow up arrow down", "⟨Up⟩⟨Up⟩⟨Down⟩"),
    ("arrow up IT", "freccia su", "⟨Up⟩"),
    ("open/close parentheses", "open parentheses foo close parentheses", "(foo)"),
    ("all caps then stop", "all caps deploy now stop caps mode please", "DEPLOY NOW please"),
    ("verb-first caps mode", "start caps mode deploy stop caps mode ok", "DEPLOY ok"),
    ("verb-first spell mode", "start spell mode al em er stop spell mode", "lmr"),
    ("delete a word from the line",
     "hello world start delete mode world stop delete mode", "hello world⌫11hello"),
    ("replace a word in the line",
     "git status start replace mode status replace with commit stop replace mode",
     "git status⌫10git commit"),
    ("undo the last typing", "hello world undo", "hello world⌫11"),
    ("redo after undo", "hello world undo redo", "hello world⌫11hello world"),
    ("delete then undo restores it",
     "alpha beta gamma start delete mode beta stop delete mode undo",
     "alpha beta gamma⌫16alpha gamma⌫11alpha beta gamma"),
    ("enter commits — line no longer editable",
     "hello invio start delete mode hello stop delete mode", "hello⟨Enter⟩"),
    ("italian maiuscolo", "maiuscolo errore", "ERRORE"),
    ("colon + semicolon IT", "due punti punto e virgola", ":;"),
    ("code fence + lang", "code block python new line print", "```python⟨Newline⟩print"),
    ("triple backticks (plural)", "show me triple backticks", "show me ```"),
    ("three backticks", "here three backticks", "here ```"),
    ("md heading two", "heading two Introduction", "## Introduction"),
    ("md bullet", "bullet first item", "- first item"),
    ("md bold wrap", "bold important", "**important**"),
    ("md italic (IT corsivo)", "corsivo nota", "*nota*"),
    ("md quote block", "block quote note", "> note"),
    ("spell mode (user example: L M R)", "spell al em er stop spelling", "lmr"),
    ("spell mode IT (compita)", "compita elle emme erre fine compitazione", "lmr"),
    ("spell mode IT word (gatto)", "compita gi a ti ti o basta lettere", "gatto"),
    ("spell IT caps", "compita maiuscolo a bi ci minuscolo fine compitazione", "ABC"),
    ("spell with capital", "spelling capital a bee see end spell", "Abc"),
    ("spell passthrough merged word", "spell cat end spell", "cat"),
    ("spell with space", "spell a space b end spell", "a b"),
    ("spell then submit", "spell em el end spell invio", "ml⟨Enter⟩"),
    ("nested modes (user's corrected example)",
     "caps mode spell mode al em er space caps mode stop eich oh spell mode stop", "LMR ho"),
    ("caps persists into spell", "caps mode spell mode al em er spell mode stop caps mode stop", "LMR"),
    ("backslash", "backslash n", "\\n"),
    ("at + hash IT", "chiocciola cancelletto", "@#"),
    ("literal escapes command", "literal slash here", "slash here"),
    ("newline IT (a capo)", "first line a capo second", "first line⟨Newline⟩second"),
    ("plain prose untouched", "please summarize the readme file", "please summarize the readme file"),
    ("tab key IT", "tabulazione done", "⟨Tab⟩done"),
]

# Prefix mode (interpret(..., prefix_mode=True)): literal by default; the grammar is a
# nested scope stack (START="(", STOP=")", COMMAND takes ONE argument).
# (description, spoken, expected)
PREFIX_CASES = [
    # nothing fires without the prefix — not even space
    ("plain prose is literal", "enter the room and sit down", "enter the room and sit down"),
    ("space is literal without prefix", "alpha space beta", "alpha space beta"),
    ("the bang bug is gone", "She bang it", "She bang it"),
    ("bare stop is literal (nothing open)", "stop right there", "stop right there"),
    # single command (multi-word commands are one unit)
    ("command + space", "command space", " "),
    ("command + key", "command enter", "⟨Enter⟩"),
    ("command + arrow", "command arrow up", "⟨Up⟩"),
    ("command + slash glues like a path", "open src command slash main", "open src/main"),
    ("each command needs its own prefix",
     "command open quotes frank command close quotes", '"frank"'),
    ("lookahead gate — bare 'command' is literal", "run this command please", "run this command please"),
    # repeat is REGION-only — in single form the trailing "<N> times" stays literal
    ("times is literal in single form", "command backspace twelve times", "⟨BSpace⟩twelve times"),
    ("times repeats inside a region (erases N chars)",
     "this is a big errorr command start backspace twelve times command stop",
     "this is a big errorr⌫12"),
    ("backword deletes N whole words",
     "alpha beta gamma command start backword 2 command stop", "alpha beta gamma⌫10"),
    # mode units (= ONE argument): command <MODE> start … <MODE> stop
    ("number unit → digits", "command number start four five number stop", "45"),
    ("caps unit", "command caps start deploy now caps stop ok", "DEPLOY NOW ok"),
    ("spell unit", "command spell start al em er spell stop", "lmr"),
    ("delete unit",
     "hello world command delete start world delete stop", "hello world⌫11hello"),
    ("replace unit",
     "git status command replace start status replace with commit replace stop",
     "git status⌫10git commit"),
    # nesting is still ONE argument: COMMAND(CAPS(SPELL(…)))
    ("nested caps over spell (one arg)",
     "command caps start spell start al em er spell stop caps stop", "LMR"),
    # a single-argument COMMAND consumes its ONE block, then the rest is literal
    ("one block then literal",
     "command number start one number stop caps start spell start al em er spell stop caps stop",
     "1 caps start spell start al em er spell stop caps stop"),
    # a region (command start … command stop) concatenates MANY arguments
    ("region concatenates siblings",
     "command start number start one number stop caps start spell start al em er "
     "spell stop caps stop command stop", "1LMR"),
    # ── the user's authoritative examples, verbatim transcripts ──
    # punctuation acts inside spelling: "dot" → "." (caps over spell over dots)
    ("U.S.A via caps+spell+dots",
     "command caps start spell start u dot es dot ae spell stop caps stop", "U.S.A"),
    # COMMAND takes ONE argument: NUMBER(one) is consumed; the trailing CAPS(SPELL(…))
    # block is a SECOND argument, so it (and everything after) stays literal.
    ("only the first argument is a command (no region)",
     "command number start one number stop caps start spell start al al am spell stop caps stop",
     "1 caps start spell start al al am spell stop caps stop"),
    # the same blocks wrapped in a region → both arguments execute: 1 + LLM
    ("a region executes every argument",
     "command start number start one number stop caps start spell start al al am "
     "spell stop caps stop command stop", "1LLM"),
]


def _run_table(title: str, cases: list, name_w: int, prefix_mode: bool) -> int:
    print(f"\n  {title}")
    print(f"┏{'━' * name_w}┳━━━━━━━━┓")
    print(f"┃ {'Test'.ljust(name_w - 1)}┃ Status ┃")
    print(f"┡{'━' * name_w}╇━━━━━━━━┩")
    failed = 0
    for desc, spoken, expected in cases:
        got = render(interpret(spoken, {}, prefix_mode=prefix_mode))
        ok = got == expected
        if not ok:
            failed += 1
        status = "PASS" if ok else "FAIL"
        print(f"│ {desc.ljust(name_w - 1)}│ {status.ljust(6)} │")
        if not ok:
            print(f"│   spoken  : {spoken!r}")
            print(f"│   expected: {expected!r}")
            print(f"│   got     : {got!r}")
    print(f"└{'─' * name_w}┴────────┘")
    return failed


def main() -> int:
    name_w = max(len(c[0]) for c in CASES + PREFIX_CASES) + 2
    failed = _run_table("Default mode (command-by-default)", CASES, name_w, prefix_mode=False)
    failed += _run_table("Prefix mode (literal-by-default)", PREFIX_CASES, name_w, prefix_mode=True)
    total = len(CASES) + len(PREFIX_CASES)
    # Persistent modes: caps/spell carry across utterances when a shared dict is passed.
    m: dict = {}
    persist = (
        render(interpret("caps mode a", m)) == "A"
        # caps persists into a new utterance; continuations are space-separated
        and render(interpret("b c", m)) == " B C"
        and render(interpret("caps mode stop d", m)) == " d"
    )
    print(f"persistent modes across utterances: {'PASS' if persist else 'FAIL'}")
    if not persist:
        failed += 1

    # RETROACTIVE cross-utterance prefix: a lone "command" (VAD split "command" |
    # "enter" off a pause) is written PROVISIONALLY, then the next utterance's
    # command deletes it (⌫7 = erase "command") and fires instead.
    p = {}
    u1 = render(interpret("command", p, prefix_mode=True))     # provisional literal "command"
    u2 = render(interpret("enter", p, prefix_mode=True))        # erase it, then fire
    retro = (u1 == "command" and u2 == "⌫7⟨Enter⟩")
    # "command" | "start …" also corrects retroactively (region opens)
    p2 = {}
    interpret("command", p2, prefix_mode=True)
    retro = retro and (render(interpret("start space command stop", p2, prefix_mode=True)) == "⌫7 ")
    # but a lone "command" followed by plain prose KEEPS the literal word (space-joined)
    p3 = {}
    interpret("command", p3, prefix_mode=True)
    retro = retro and (render(interpret("hello there", p3, prefix_mode=True)) == " hello there")
    print(f"lone 'command' self-corrects retroactively: {'PASS' if retro else 'FAIL'}")
    if not retro:
        failed += 1

    # WORD-BY-WORD tolerance: the VAD splits each word into its own utterance AND the
    # ASR splits the trigger into "command" + "come and". The filler tail is swallowed
    # (typed: nothing) and the arm survives, so a later "start" still opens the region,
    # and a split "command" + "stop" still closes it.
    w = {}
    s1 = render(interpret("command", w, prefix_mode=True))      # provisional "command"
    s2 = render(interpret("come and", w, prefix_mode=True))     # filler tail → swallowed
    s3 = render(interpret("start", w, prefix_mode=True))        # completes → open region
    s4 = render(interpret("slash", w, prefix_mode=True))        # inside region → a command fires
    s5 = render(interpret("command", w, prefix_mode=True))      # provisional " command" (space before, line="/")
    s6 = render(interpret("stop", w, prefix_mode=True))         # split close → erase the 8-char provisional, region closes
    wbw = (s1 == "command" and s2 == "" and s3 == "⌫7"
           and s4 == "/" and s5 == " command" and s6 == "⌫8")
    # "commande" (the ASR's frequent spelling of the trigger) also arms
    w2 = {}
    interpret("commande", w2, prefix_mode=True)
    wbw = wbw and (render(interpret("enter", w2, prefix_mode=True)) == "⌫8⟨Enter⟩")
    # Split AFTER the mode word — the real phrase-2 failure: "command caps" | "start deploy
    # caps stop" must reconstruct "command caps start …" and yield the net line "DEPLOY".
    w3 = {}
    interpret("command caps", w3, prefix_mode=True)                 # arm pending mode = caps
    interpret("start deploy caps stop", w3, prefix_mode=True)       # reconstruct → uppercases content
    wbw = wbw and (w3.get("line") == "DEPLOY")
    print(f"word-by-word command (split trigger + filler tail): {'PASS' if wbw else 'FAIL'}")
    if not wbw:
        print(f"  got: s1={s1!r} s2={s2!r} s3={s3!r} s4={s4!r} s5={s5!r} s6={s6!r} "
              f"split_mode_line={w3.get('line')!r}")
        failed += 1

    # Continuation merge: a thinking pause splits one sentence; the continuation
    # opens with a continuation word, so we strip Whisper's pause-"?" and lowercase
    # the opener, flowing the two fragments into one line.
    c = {}
    interpret("Can't you replace?", c, prefix_mode=True)        # fragment ends with "?"
    merged = render(interpret("The fake stripe test better.", c, prefix_mode=True))
    cont = (merged == "⌫1 the fake stripe test better.")
    # two genuine sentences (opener is NOT a continuation word) just get a space
    d = {}
    interpret("First sentence.", d, prefix_mode=True)
    cont = cont and (render(interpret("Second one.", d, prefix_mode=True)) == " Second one.")
    print(f"continuation merge across a pause: {'PASS' if cont else 'FAIL'}")
    if not cont:
        failed += 1

    # Whisper hallucination filter: canned phrases / punctuation / music -> dropped;
    # real words (even single ones) -> kept.
    hall = (
        looks_like_hallucination("Thanks for watching")
        and looks_like_hallucination("thank you.")
        and looks_like_hallucination("   ")
        and looks_like_hallucination("♪♪♪")
        and looks_like_hallucination("grazie mille")
        and not looks_like_hallucination("hello world")
        and not looks_like_hallucination("you")
        and not looks_like_hallucination("git status")
    )
    print(f"hallucination filter: {'PASS' if hall else 'FAIL'}")
    if not hall:
        failed += 1

    print(f"{total - failed}/{total} passed." + (" All green." if failed == 0 else f" {failed} FAILED."))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
