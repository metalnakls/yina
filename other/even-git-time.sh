#!/bin/bash

# Shared timing helpers for release scripts using the maintainer's Moscow rule.
is_allowed_even_git_minute() {
  local hour_text minute_text hour minute
  read -r hour_text minute_text <<<"$(TZ=Europe/Moscow date '+%H %M')"
  hour=$((10#$hour_text))
  minute=$((10#$minute_text))
  (( minute % 2 == 0 && minute != 30 && minute != 50 && (minute != 0 || hour % 2 == 0 || hour == 1) ))
}

wait_for_even_git_minute() {
  while ! is_allowed_even_git_minute; do sleep 1; done
}

nearest_even_git_timestamp() {
  local epoch hour_text minute_text hour minute
  epoch=$(( $(date '+%s') / 60 * 60 ))
  while true; do
    read -r hour_text minute_text <<<"$(TZ=Europe/Moscow date -r "$epoch" '+%H %M')"
    hour=$((10#$hour_text))
    minute=$((10#$minute_text))
    if (( minute % 2 == 0 && minute != 30 && minute != 50 && (minute != 0 || hour % 2 == 0 || hour == 1) )); then
      TZ=Europe/Moscow date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z'
      return
    fi
    epoch=$((epoch - 60))
  done
}
