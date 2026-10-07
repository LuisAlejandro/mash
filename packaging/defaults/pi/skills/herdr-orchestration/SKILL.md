---
name: herdr-orchestration
description: "Coordinate supervised Pi workers in sibling Herdr panes. Use when the user asks to supervise, wait for workers, or run a local orchestration loop. Questions from a worker are answered by this coordinator. Do not use for ordinary terminal control."
---

# Herdr orchestration

You are the coordinator. The `herdr-orchestration` CLI holds the Run, the Tasks, and the inbox. Herdr only places the worker pane. Pi in that pane owns the prompt.

Require `HERDR_ENV=1`. If it is not set, say you are not inside Herdr and stop.

## Loop

1. `herdr-orchestration run-create --objective "<objective>"`
2. `herdr-orchestration worker-start --spec "<self-contained task>"` for each independent worker. The spec names the target, the change, the constraints, who may edit what, and the evidence that proves it.
3. `herdr-orchestration check --wait --types question,worker_done --timeout-ms 900000`
4. On a `question` delivery, decide the answer. You may ask the person in this pane with `ask_user` before you answer. Then `herdr-orchestration reply --id <message-id> --body "<answer>"`. Reply does not acknowledge the delivery.
5. On `worker_done`, do one of these:
   - `herdr-orchestration reuse --dispatch <id> --spec "<next task>"` to give that same pane another task
   - `herdr-orchestration retain --dispatch <id>` to leave the pane open
   - `herdr-orchestration release --dispatch <id>` to close a pane that dispatch created
6. `herdr-orchestration check --ack <message-id>` after the delivery is handled.

Repeat until every dispatch is settled and then reused, retained, or released. `herdr-orchestration list` shows the run.

A `check` that returns `timeout` changes nothing. Run `list`. An `exited` dispatch means the pane process ended without `worker_done`. Report that. Do not release it and do not start a replacement unless the person asks.

Idle is not completion. Do not treat `herdr agent prompt --wait` as `worker_done`. Do not type an answer into a worker pane with `herdr agent send-keys`. The worker receives your `reply` as the result of `ask_coordinator`.

`release` closes only a pane that dispatch created. A reused dispatch shares the original pane; release the dispatch that created it, after the later task has settled.
