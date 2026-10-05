#!/usr/bin/env bash

# Pi writes one JSON object per line. Assistant messages carry provider usage
# inside `message.usage`, including input/cacheRead/cacheWrite counters.
pi_latest_usage() {
  local path=$1
  [[ -f "$path" ]] || return 1
  tail -n 500 "$path" 2>/dev/null | jq -Rrn '
    def number_or_zero($value):
      if ($value | type) == "number" and $value >= 0 and ($value | floor) == $value
      then $value
      else 0
      end;
    def timestamp_text($value):
      if ($value | type) == "number" then
        (($value / 1000) | floor | strftime("%Y-%m-%dT%H:%M:%SZ"))
      elif ($value | type) == "string" then $value
      else ""
      end;
    reduce (inputs | fromjson? | select(type == "object" and ((.message.usage // .usage) | type) == "object")) as $row
      (null;
       ($row.message.usage // $row.usage) as $usage |
       ($usage.input // $usage.inputTokens // $usage.input_tokens) as $input |
       if ($input | type) == "number" and $input >= 0 and ($input | floor) == $input then
         . = {
           ts: timestamp_text($row.timestamp // $row.message.timestamp // ""),
           input: $input,
           read: number_or_zero($usage.cacheRead // $usage.cache_read_input_tokens),
           write: number_or_zero($usage.cacheWrite // $usage.cache_write_input_tokens),
           model: ($row.message.model // $row.model // "pi"),
           provider: ($row.message.provider // $row.provider // $row.message.api // $row.api // "unknown")
         }
       else . end) |
    select(. != null and .ts != "") |
    [.ts, .input, .read, .write, .model, .provider] | @tsv' 2>/dev/null
}

pi_usage() {
  local session_path=$1 supplied=${3:-} path record ts input read write model provider
  path="$session_path"
  [[ -f "$path" ]] || path="$supplied"
  [[ -f "$path" ]] || return 1
  record=$(pi_latest_usage "$path") || return 1
  [[ -n "$record" ]] || return 1
  IFS=$'\t' read -r ts input read write model provider <<<"$record"
  [[ -n "$model" ]] || model=pi
  [[ -n "$provider" ]] || provider=unknown
  printf 'pi\t%s\t%s\t%s\t%s\t%s\t0\t0\t%s\t%s\t%s\t0\n' \
    "$path" "$ts" "$input" "$read" "$write" "$model" "$provider" "$path"
}
