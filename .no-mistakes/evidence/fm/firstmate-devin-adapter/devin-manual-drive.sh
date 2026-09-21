#!/usr/bin/env bash
# Manual live drive of the Devin worker adapter, keeping styled pane captures.
# Mirrors tests/fm-devin-signals-live-e2e.test.sh setup; evidence stays in $EV.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
MODEL=${MODEL:-swe-2-medium}
. "$ROOT/tests/fixtures.sh"
. "$ROOT/bin/fm-busy-lib.sh"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-composer-lib.sh"
DEVIN_BIN=$(command -v devin)
REAL_TMUX=$(command -v tmux)
VERSION=$(devin --version)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/dvman.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/tmux.sock"
cleanup() { "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$LAB"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" | tee -a "$EV/devin-manual-drive.log" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1" | tee -a "$EV/devin-manual-drive.log"; }
: > "$EV/devin-manual-drive.log"
H="$LAB/home"; WT="$LAB/wt"; PROJ="$LAB/project"; ID=devin-manual
fm_test_spawn_home "$H" devin
fm_git_worktree "$PROJ" "$WT" devin-manual
mkdir -p "$H/user-home/.local/share/devin" "$H/user-home/.config/devin" "$LAB/bin"
cp "$HOME/.local/share/devin/credentials.toml" "$H/user-home/.local/share/devin/credentials.toml"
chmod 600 "$H/user-home/.local/share/devin/credentials.toml"
printf '{}\n' > "$H/user-home/.config/devin/config.json"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: compute 12345 plus 67890 using your shell tool and write only the result into answer.txt. Do no other work and do not delegate. Later read and acknowledge Firstmate's instruction inbox when the doorbell arrives."
fakebin=$(make_spawn_fakebin "$LAB/fake" claude)
ln -s "$DEVIN_BIN" "$fakebin/devin"

# Adversarial: a secondmate launch on devin must be refused by the real spawn path.
if out=$(fm_test_run_spawn "$H" "$WT" "$fakebin" devin-sm "$PROJ" --secondmate --harness devin 2>&1); then
  fail "secondmate launch on devin was accepted: $out"
fi
printf '%s\n' "$out" > "$EV/devin-secondmate-refusal.txt"
case "$out" in *'crewmate/scout adapter only'*) ok "secondmate launch refused: $out" ;; *) fail "unexpected refusal text: $out" ;; esac

FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" \
  --scout --harness devin --model "$MODEL" --effort high > "$LAB/spawn.log" 2>&1 \
  || fail "fm-spawn failed: $(cat "$LAB/spawn.log")"
sed "s#$LAB#<lab>#g" "$LAB/launch.sh" > "$EV/devin-launch-command.sh"
sed "s#$LAB#<lab>#g" "$H/state/$ID.meta" > "$EV/devin-task-meta.txt"
jq . "$H/state/$ID.devin-config.json" | sed "s#$LAB#<lab>#g; s#$ROOT#<root>#g" > "$EV/devin-private-config.json"
ok "fm-spawn produced launch command, meta, private config for model $MODEL"

printf '#!/bin/sh\nexec "%s" -S "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH" FM_HOME="$H"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TARGET="firstmate:fm-$ID"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 120 -y 40 -c "$WT" \
  "HOME='$H/user-home' /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc" || fail 'could not start pane'
capture() { "$REAL_TMUX" -S "$SOCKET" capture-pane -p -e -t "$TARGET"; }
snap() { capture > "$EV/pane-$1.ansi"; "$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "$TARGET" > "$EV/pane-$1.txt"; }
busy() { fm_busy_classify tmux "$TARGET" devin "$ID" "$H/state"; }
wait_file() { local i; for i in $(seq 1 480); do [ -s "$1" ] && return 0; sleep 0.5; done; fail "timed out waiting for ${1##*/}"; }
wait_idle() { local i; for i in $(seq 1 240); do [ "$(busy)" = 'idle devin-hook' ] && return 0; sleep 0.5; done; fail "Stop did not produce semantic idle (busy=$(busy))"; }

echo "busy after spawn: $(busy)" >> "$EV/devin-manual-drive.log"
[ "$(busy)" = 'busy fm-spawn' ] || fail "launch not armed: $(busy)"
for i in $(seq 1 120); do [ "$(busy)" = 'busy devin-hook' ] && break; sleep 0.5; done
echo "busy during launch brief: $(busy)" >> "$EV/devin-manual-drive.log"
snap 1-launch-busy
wait_file "$WT/answer.txt"
[ "$(tr -d '[:space:]' < "$WT/answer.txt")" = 80235 ] || fail 'launch brief did not execute'
wait_idle
snap 2-idle-after-brief
[ -f "$H/state/$ID.turn-ended" ] || fail 'no turn-ended notification'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'devin not alive'
ok "launch brief executed (answer.txt=80235), Stop hook settled to $(busy), agent alive"

verdict=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1\nrows=0' "$(capture)" \
  "$(tmux display-message -p -t "$TARGET" '#{cursor_y}')" devin)
echo "idle composer verdict: $verdict" >> "$EV/devin-manual-drive.log"
case "$verdict" in empty*) ok "idle composer classified $verdict" ;; *) fail "idle composer was $verdict" ;; esac

"$ROOT/bin/fm-send.sh" "$ID" 'Runtime steering verification: compute 31 times 37 and write only the result to steer.txt. Acknowledge this instruction by moving its .msg file into handled/ as instructed by the doorbell. Do no other work.' > "$LAB/send.log" 2>&1 || fail "steer failed: $(cat "$LAB/send.log")"
sed "s#$LAB#<lab>#g" "$LAB/send.log" > "$EV/devin-fm-send.log"
sleep 3; snap 3-steer-doorbell
wait_file "$WT/steer.txt"
wait_file "$H/state/$ID.inbox/handled/001.msg"
[ "$(tr -d '[:space:]' < "$WT/steer.txt")" = 1147 ] || fail 'wrong steering result'
wait_idle
snap 4-idle-after-steer
ok "fm-send doorbell: steer.txt=1147, inbox message acknowledged into handled/, settled to $(busy)"

"$ROOT/bin/fm-send.sh" "$ID" 'Runtime interrupt verification: run sleep 90 in your shell tool, then wait for it to finish. Do not respond before it finishes.' > "$LAB/send.log" 2>&1 || fail 'could not steer interrupt probe'
seen=0
for _ in $(seq 1 240); do
  if [ "$(busy)" = 'busy devin-hook' ] && capture | fm_busy_lines_match devin; then seen=1; break; fi
  sleep 0.5
done
[ "$seen" = 1 ] || fail 'no semantic and rendered busy during interrupt probe'
snap 5-busy-before-interrupt
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
sed "s#$LAB#<lab>#g" "$LAB/interrupt.log" > "$EV/devin-fm-control-interrupt.log"
echo "busy after interrupt: $(busy)" >> "$EV/devin-manual-drive.log"
[ "$(busy)" = 'unknown fm-interrupt' ] || fail "interrupt did not invalidate to unknown: $(busy)"
for _ in $(seq 1 60); do capture | grep -q 'Canceled. What should Devin do?' && break; sleep 0.5; done
snap 6-after-interrupt
capture | grep -q 'Canceled. What should Devin do?' || fail 'double Escape did not cancel'
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail 'devin died on interrupt'
ok "fm-control interrupt: Devin rendered Canceled, agent alive, state $(busy), $(grep -o 'cancel=[a-z]*' "$LAB/interrupt.log" | head -1)"

"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
sed "s#$LAB#<lab>#g" "$LAB/exit.log" > "$EV/devin-fm-control-exit.log"
sleep 1; snap 7-after-exit
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail 'quit did not return to shell'
echo "busy after exit: $(busy)" >> "$EV/devin-manual-drive.log"
cp "$H/state/$ID.busy-state" "$EV/devin-busy-state-final.txt" 2>/dev/null || true
ok "fm-control exit: /quit returned the pane to a shell; busy record: $(busy)"
ok "$VERSION manual drive complete (model $MODEL)"
