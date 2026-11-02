# ticktick.el

[![MELPA](https://melpa.org/packages/ticktick-badge.svg)](https://melpa.org/#/ticktick)
[![MELPA Stable](https://stable.melpa.org/packages/ticktick-badge.svg)](https://stable.melpa.org/#/ticktick)

ticktick.el enables two-way synchronization between [TickTick](https://ticktick.com), a popular task management app, and Emacs Org Mode. This is a newer project, so you might wish to [backup your TickTick data](https://help.ticktick.com/articles/7055781405648748544).

![alt text](screenshot.png)

## Features

- **Bidirectional sync** with saved baselines, field-level merging, and explicit conflict review
- **OAuth2 authentication**
- **Preserves task metadata**: priorities, due dates, completion status, descriptions, tags
- **Project-based organization** matching TickTick's structure
- **Automatic syncing** on focus changes or timer-based intervals
- **Tag synchronization** using Org mode's native tag syntax

## Installation

### Manual
1. Clone this repository:
   ```bash
   git clone https://github.com/polhuang/ticktick.el.git
   ```

2. Add to your Emacs configuration:
   ```elisp
   (add-to-list 'load-path "/path/to/ticktick.el")
   (require 'ticktick)
   ```

### From MELPA

Add to your Emacs configuration:
```elisp
(use-package ticktick
  :ensure t)

```

### 
## Setup

### 1. Register TickTick OAuth Application

1. Go to https://developer.ticktick.com
2. Create a new OAuth application
3. Set the redirect URI to: `http://localhost:8080/ticktick-callback`
4. Note your Client ID and Client Secret

### 2. Configure Credentials

```elisp
(setq ticktick-client-id "your-client-id"
      ticktick-client-secret "your-client-secret")
```

Instead of hard-coding your client secret into your configuration, storing it with [auth-source](https://www.gnu.org/software/emacs/manual/html_mono/auth.html) is recommended. `ticktick-client-secret` accepts a function of no arguments in place of a string:

```elisp
(setq ticktick-client-id "your-client-id"
      ticktick-client-secret
      (lambda ()
        (auth-source-pick-first-password :host "ticktick.com" :user ticktick-client-id)))
```
### 3. Authorize Application

```
M-x ticktick-authorize
```

This will open your browser for OAuth consent and automatically capture the authorization.

### 4. Perform Initial Sync

```
M-x ticktick-sync
```

## Usage

### Main Commands

| Command | Description |
|---------|-------------|
| `ticktick-sync` | Fetch, compare, and reconcile both sides |
| `ticktick-preview-sync` | Preview changes without writing tasks |
| `ticktick-review-conflicts` | Review and resolve conflicting tasks |
| `ticktick-fetch-to-org` | Pull tasks from TickTick to Org |
| `ticktick-push-from-org` | Push Org tasks to TickTick |
| `ticktick-authorize` | Set up OAuth authentication |
| `ticktick-refresh-token` | Manually refresh auth token |
| `ticktick-toggle-sync-timer` | Toggle automatic timer-based syncing |

### Org File Structure

Tasks are stored in `~/.emacs.d/ticktick/ticktick.org` with this structure:

```org
* Project Name
:PROPERTIES:
:TICKTICK_PROJECT_ID: abc123
:END:
** TODO [#A] Task Title
DEADLINE: <2024-01-15 Mon>
:PROPERTIES:
:TICKTICK_ID: def456
:TICKTICK_ETAG: xyz789
:SYNC_CACHE: hash
:LAST_SYNCED: 2024-01-15T10:30:00+0000
:END:
Task description content here.
```

## Configuration

### Key Variables

```elisp
;; Path to the org file for tasks (default: ~/.emacs.d/ticktick/ticktick.org)
(setq ticktick-sync-file "/path/to/your/ticktick.org")

;; Directory for storing tokens and data (default: ~/.emacs.d/ticktick/)
(setq ticktick-dir "/path/to/ticktick/data/")

;; Enable automatic syncing on focus loss (default: nil)
(setq ticktick-autosync t)
(ticktick-enable-autosync-on-blur)

;; Enable automatic syncing every N minutes (default: nil)
(setq ticktick-sync-interval 30)

;; Port for OAuth callback server (default: 8080)
(setq ticktick-httpd-port 8080)
```

### Automatic Syncing

Enable automatic syncing with one of these methods:

**Focus-based syncing** (syncs when Emacs loses window focus):
```elisp
(setq ticktick-autosync t)
(ticktick-enable-autosync-on-blur)
```

**Timer-based syncing** (syncs every N minutes):
```elisp
(setq ticktick-sync-interval 30)
(ticktick-toggle-sync-timer)
```

You can also toggle timer syncing interactively:
```
M-x ticktick-toggle-sync-timer
```

## Task Management

### Creating Tasks

Create tasks by just adding a `TODO` heading directly in your org file under any project heading:

```org
* Work Project
:PROPERTIES:
:TICKTICK_PROJECT_ID: project123
:END:
** TODO [#A] Review quarterly reports
DEADLINE: <2024-01-20 Sat>
Need to analyze Q4 performance metrics and prepare summary.
```

Run `M-x ticktick-push-from-org` to sync to TickTick.

### Task Priorities

Org priorities are mapped to TickTick priorities.

- `[#A]` - High priority
- `[#B]` - Normal priority  
- `[#C]` - Low priority
- No priority - Normal priority

### Task Status

- `TODO` - Open task
- `DONE` - Completed task

### Tags

Tags are synchronized between TickTick and Org mode using Org's native tag syntax:

```org
** TODO [#A] Task with tags     :work:urgent:
DEADLINE: <2024-01-20 Sat>
Task description here.
```

Tags from TickTick are automatically converted to Org tags, and any tags you add to tasks in Org will be synced back to TickTick.

## Conflict resolution

`ticktick-sync` fetches remote tasks before writing changes. It compares each task with the last successfully reconciled version, saved in `.ticktick-state.el` under `ticktick-dir`.

Independent edits merge automatically: changing a title in Org and a priority in TickTick preserves both changes. Different edits to the same field leave the entire task unresolved. Descriptions, tag lists, and deadline details are each compared as whole fields. New installations import remote tasks and create local tasks; existing matching IDs without a baseline require review if their values differ.

Run `M-x ticktick-preview-sync` to inspect a plan, or `M-x ticktick-review-conflicts` after syncing. The review shows the base, Org, and TickTick versions. Choose either copy, edit a merged task, delete both copies, or leave the task deferred. In the merge editor, `C-c C-c` applies the result and `C-c C-k` cancels. `g` in the review fetches fresh versions. A resolution is refused if either source has changed since it was reviewed.

The directional commands preserve conflicts too. A merge requiring writes to both sides is deferred until a full `ticktick-sync`. Background syncing records conflicts without asking interactive questions.

### Deletions and interrupted syncs

The default `ticktick-delete-behavior` is `ask`, which queues deletions for review. `archive` archives local removals, `delete` applies unambiguous deletions automatically, and `sync-only` keeps deletion decisions pending. A task edited on one side and deleted on the other always requires review. Keeping an edited Org task after remote deletion recreates it and records the new ID.

Pending operations are saved before mutation. A later sync can finish a verified remote write whose local save failed. An uncertain creation is never submitted again automatically: attach the returned task ID using `ticktick-link-pending-creation`, or explicitly verify that no remote copy exists before using `ticktick-retry-pending-creation`. Both actions are available in the review buffer.

Deadlines preserve time, time zone, and second precision; Org displays timed deadlines in Emacs's local time zone. Unrelated Org properties are preserved. Do not remove the state file as routine cleanup: it contains baselines and pending operations needed for recovery.

The API does not document atomic conditional updates, so a small race remains between the final remote check and a write. Completed tasks already known to the package are fetched individually if absent from project data; this is not a full completed-history import. Reopening completed tasks is currently refused. See [the API constraints and design notes](docs/synchronization.md).

## Development

Install the `request` and `simple-httpd` dependencies, then run `make test`. For dependencies outside the normal Emacs package directories, pass `LOAD_PATH="-L /path/to/request -L /path/to/simple-httpd"`. Tests use temporary Org and state files with a simulated API; they do not access a live TickTick account.
