"""Tests for the bilingual verbal-command interpreter. Run: python server/test_voice_commands.py"""

from voice_commands import interpret, render

# (description, spoken transcript, expected rendered output)
CASES = [
    ("slash command", "slash context", "/context"),
    ("path with dashes", "tilde slash Code slash my dash project slash", "~/Code/my-project/"),
    ("barra is pipe (IT)", "ls barra grep foo", "ls|grep foo"),
    ("barra rovesciata = backslash", "barra rovesciata n", "\\n"),
    ("shift-invio newline (hyphen)", "uno shift-invio due", "uno⟨Newline⟩due"),
    ("italian enter (invio)", "git status invio", "git status⟨Enter⟩"),
    ("english enter", "run the tests submit", "run the tests⟨Enter⟩"),
    ("open/close paren", "open paren foo close paren", "(foo)"),
    ("wrap in parens", "in parens hello", "(hello)"),
    ("italian wrap (tra parentesi)", "tra parentesi ciao", "(ciao)"),
    ("italian square brackets", "tra parentesi quadre x", "[x]"),
    ("all caps then off", "all caps deploy now caps off please", "DEPLOY NOW please"),
    ("italian maiuscolo", "maiuscolo errore", "ERRORE"),
    ("colon + semicolon IT", "due punti punto e virgola", ":;"),
    ("code fence + lang", "code block python new line print", "```python⟨Newline⟩print"),
    ("backslash", "backslash n", "\\n"),
    ("at + hash IT", "chiocciola cancelletto", "@#"),
    ("literal escapes command", "literal slash here", "slash here"),
    ("newline IT (a capo)", "first line a capo second", "first line⟨Newline⟩second"),
    ("plain prose untouched", "please summarize the readme file", "please summarize the readme file"),
    ("in backticks", "in backticks npm install", "`npm` install"),
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
    print(f"{total - failed}/{total} passed." + (" All green." if failed == 0 else f" {failed} FAILED."))
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
