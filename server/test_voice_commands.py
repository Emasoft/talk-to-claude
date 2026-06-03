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


def main() -> int:
    name_w = max(len(c[0]) for c in CASES) + 2
    print(f"┏{'━' * name_w}┳━━━━━━━━┓")
    print(f"┃ {'Test'.ljust(name_w - 1)}┃ Status ┃")
    print(f"┡{'━' * name_w}╇━━━━━━━━┩")
    failed = 0
    for desc, spoken, expected in CASES:
        got = render(interpret(spoken))
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
    total = len(CASES)
    # Persistent modes: caps/spell carry across utterances when a shared dict is passed.
    m: dict = {}
    persist = (
        render(interpret("caps mode a", m)) == "A"
        and render(interpret("b c", m)) == "B C"   # caps persisted into a new utterance
        and render(interpret("caps mode stop d", m)) == "d"
    )
    print(f"persistent modes across utterances: {'PASS' if persist else 'FAIL'}")
    if not persist:
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
