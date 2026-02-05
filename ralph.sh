#!/usr/bin/env bash

mkdir -p /var/tmp/ralph-log

while true; do
  count=$(br ready --json 2>/dev/null | jq 'length')
  if [ "$count" -eq 0 ]; then
    echo "No more ready issues, stopping."
    break
  fi
  logfile="/var/tmp/ralph-log/run-$(date +%Y%m%d-%H%M%S).log"
  echo "=== $count issue(s) ready, logging to $logfile ==="
  cat prompts/build.txt | opencode run --model anthropic/claude-opus-4-6 > "$logfile" 2>&1
done
