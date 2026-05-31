#!/usr/bin/env bash
set -euo pipefail

clear
printf '\033[1;32m$ stream-guard-terminal-fixture --font-check\033[0m\n\n'
printf '\033[2mThis prints real terminal text using your current terminal font.\033[0m\n'
printf '\033[2mStart Stream Guard monitoring, keep this terminal visible, and wait for ARMED.\033[0m\n\n'

printf '\033[1;33m[warn]\033[0m possible leaked contact:\n'
printf '       email: \033[1;31mleak-test@example.com\033[0m\n'
printf '       phone: \033[1;31m(555) 123-4567\033[0m\n'
printf '       site:  \033[1;31mhttps://secret.example.test/login\033[0m\n\n'

printf '\033[1;33m[warn]\033[0m blocklist phrase fixtures:\n'
printf '       phrase: \033[1;31mexact-ban\033[0m\n'
printf '       phrase: \033[1;31mbad phrase\033[0m\n'
printf '       phrase: \033[1;31mprivate stream notes\033[0m\n\n'

printf '\033[1;36mSplit phone fixture:\033[0m\n'
printf '       chunk A: \033[1;37m555\033[0m\n'
printf '       chunk B: \033[1;37m123-4567\033[0m\n\n'

printf '\033[2mPress Ctrl+C when done. This screen will stay visible.\033[0m\n'
while true; do
  sleep 3600
done
