# Stream Guard Test Fixtures

Open these pages while Stream Guard monitoring is running:

- `fake-terminal.html` - fake terminal/TUI with email, phone, URL, `exact-ban`, and `bad phrase`.
- `card-fixture.html` - high-contrast card layout with email, phone, URL, and phrase text.
- `split-frame.html` - visually separated phone number chunks to exercise compact merge detection.
- `safe-control.html` - no sensitive text; use this to verify Stream Guard clears after `clearFrames`.
- `terminal-fixture.sh` - real terminal/TUI-style fixture using your current terminal font.

Quick open from the project root:

```bash
open test-fixtures/fake-terminal.html
open test-fixtures/card-fixture.html
open test-fixtures/split-frame.html
open test-fixtures/safe-control.html
bash test-fixtures/terminal-fixture.sh
```

Suggested test flow:

1. Run `make run`.
2. Start monitoring from the menu bar.
3. Open `safe-control.html` and confirm the app remains clear.
4. Open `fake-terminal.html` or `card-fixture.html` and wait for blackout.
5. Switch back to `safe-control.html` and wait for clear.
6. Run `bash test-fixtures/terminal-fixture.sh` in your real terminal to test OCR against your terminal font.
