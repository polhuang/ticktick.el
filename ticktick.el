;;; ticktick.el --- Sync Org Mode tasks with TickTick -*- lexical-binding: t; -*-

;; Author: Paul Huang
;; Version: 1.0.1
;; Package-Requires: ((emacs "27.1") (request "0.3.0") (simple-httpd "1.5.0"))
;; Keywords: tools, ticktick, org, tasks, todo
;; URL: https://github.com/polhuang/ticktick.el

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;; 
;; ticktick.el provides two-way synchronization between TickTick
;; (a popular task management service) and Emacs Org Mode.
;;
;; FEATURES:
;;
;; - Bidirectional sync: changes in either TickTick or Org Mode are reflected
;;   in both systems
;; - Task deletion synchronization: deletions on one side propagate to the other
;; - Configurable deletion behavior: ask, archive, or auto-delete
;; - OAuth2 authentication with automatic token refresh
;; - Preserves task metadata: priorities, due dates, completion status,
;;   descriptions, and tags
;; - Project-based organization matching TickTick's structure
;; - Optional automatic syncing on focus changes and timer-based intervals
;; - Tag synchronization using Org mode's native tag syntax
;;
;; SETUP:
;;
;; 1. Register a TickTick OAuth application at:
;;    https://developer.ticktick.com/
;;
;; 2. Configure your credentials:
;;    (setq ticktick-client-id "your-client-id")
;;    (setq ticktick-client-secret "your-client-secret")
;;
;; 3. Authorize the application:
;;    M-x ticktick-authorize
;;
;; 4. Perform initial sync:
;;    M-x ticktick-sync
;;
;; USAGE:
;;
;; Main commands:
;; - `ticktick-sync': Full bidirectional sync (includes deletion sync)
;; - `ticktick-fetch-to-org': Pull tasks from TickTick to Org
;; - `ticktick-push-from-org': Push Org tasks to TickTick
;; - `ticktick-authorize': Set up OAuth authentication
;; - `ticktick-refresh-token': Manually refresh auth token
;; - `ticktick-toggle-sync-timer': Toggle automatic timer-based syncing
;; - `ticktick-delete-task-at-point': Delete task at cursor from both sides
;; - `ticktick-show-sync-state': View current synchronization state
;; - `ticktick-retry-failed-deletions': Retry any failed deletion operations
;; - `ticktick-clear-sync-state': Reset sync state (use if corrupted)
;;
;; Tasks are stored in the file specified by `ticktick-sync-file'
;; (defaults to ~/.emacs.d/ticktick/ticktick.org) with this structure:
;;
;; * Project Name
;; :PROPERTIES:
;; :TICKTICK_PROJECT_ID: abc123
;; :END:
;; ** TODO Task Title [#A]                                    :work:urgent:
;; DEADLINE: <2024-01-15 Mon>
;; :PROPERTIES:
;; :TICKTICK_ID: def456
;; :TICKTICK_ETAG: xyz789
;; :SYNC_CACHE: hash
;; :LAST_SYNCED: 2025-01-15T10:30:00+0000
;; :END:
;; Task description content here.
;;
;; CUSTOMIZATION:
;;
;; Key variables you can customize:
;; - `ticktick-sync-file': Path to the org file for tasks
;; - `ticktick-dir': Directory for storing tokens and data
;; - `ticktick-autosync': Enable automatic syncing on focus changes
;; - `ticktick-sync-interval': Enable automatic syncing every N minutes
;; - `ticktick-httpd-port': Port for OAuth callback server
;; - `ticktick-delete-behavior': How to handle deletions (ask/archive/delete/sync-only)
;; - `ticktick-archive-location': Where to archive deleted tasks (separate-file/archive-heading)
;; - `ticktick-archive-file': Path to archive file for deleted tasks
;; - `ticktick-confirm-deletions': Whether to prompt for deletion confirmation
;; - `ticktick-deletion-conflict-policy': How to resolve modify-delete conflicts
;;
;; For debugging OAuth issues:
;; M-x ticktick-debug-oauth

;;; Code:

(require 'request)
(require 'json)
(require 'url)
(require 'org)
(require 'org-element)
(require 'subr-x)
(require 'simple-httpd)
(require 'cl-lib)

(defgroup ticktick nil
  "Interface with TickTick API."
  :prefix "ticktick-"
  :group 'applications)

(defcustom ticktick-client-id ""
  "TickTick client ID."
  :type 'string
  :group 'ticktick)

(defcustom ticktick-client-secret ""
  "TickTick client secret."
  :type 'string
  :group 'ticktick)

(defcustom ticktick-auth-scopes "tasks:write tasks:read"
  "Space-separated scopes for TickTick API access."
  :type 'string
  :group 'ticktick)


(defcustom ticktick-dir
  (concat user-emacs-directory "ticktick/")
  "Folder in which to save token."
  :group 'ticktick
  :type 'string)

(defcustom ticktick-token-file
  (expand-file-name ".ticktick-token" ticktick-dir)
  "File in which to store TickTick OAuth token."
  :type 'file
  :group 'ticktick)

(defcustom ticktick-sync-file (expand-file-name "ticktick.org" ticktick-dir)
  "Path to the org file where all TickTick tasks will be synchronized."
  :type 'file
  :group 'ticktick)


(defcustom ticktick-autosync nil
  "If non-nil, automatically sync when switching buffers or losing focus."
  :type 'boolean
  :group 'ticktick)

(defcustom ticktick-httpd-port 8080
  "Local port for the OAuth callback server."
  :type 'integer
  :group 'ticktick)

(defcustom ticktick-redirect-uri "http://localhost:8080/ticktick-callback"
  "Redirect URI registered with TickTick. Must match OAuth app settings."
  :type 'string
  :group 'ticktick)

(defcustom ticktick-sync-interval nil
  "Interval in minutes for automatic syncing. If nil, timer-based sync is disabled.
When set to a positive number, TickTick will sync automatically every N minutes.
After changing this value, call `ticktick-toggle-sync-timer' to apply changes."
  :type '(choice (const :tag "Disabled" nil)
                 (integer :tag "Minutes"))
  :group 'ticktick)

(defcustom ticktick-delete-behavior 'ask
  "How to handle task deletions during sync.
- `ask': Prompt user for confirmation before each deletion
- `archive': Move deleted tasks to archive instead of deleting
- `delete': Delete tasks without confirmation
- `sync-only': Only sync new/modified tasks, never delete"
  :type '(choice (const :tag "Ask for confirmation" ask)
                 (const :tag "Archive instead of delete" archive)
                 (const :tag "Delete without confirmation" delete)
                 (const :tag "Never delete (sync only)" sync-only))
  :group 'ticktick)

(defcustom ticktick-archive-location 'separate-file
  "Where to archive deleted tasks.
- `separate-file': Archive to a separate file specified by `ticktick-archive-file'
- `archive-heading': Archive under an \"Archived Tasks\" heading in the sync file"
  :type '(choice (const :tag "Separate archive file" separate-file)
                 (const :tag "Archive heading in sync file" archive-heading))
  :group 'ticktick)

(defcustom ticktick-archive-file
  (expand-file-name "ticktick-archive.org" ticktick-dir)
  "Path to the archive file for deleted tasks."
  :type 'file
  :group 'ticktick)

(defcustom ticktick-confirm-deletions t
  "If non-nil, ask for confirmation before deleting tasks.
This setting is overridden when `ticktick-delete-behavior' is set to `delete'."
  :type 'boolean
  :group 'ticktick)

(defcustom ticktick-deletion-conflict-policy 'keep-newest
  "How to resolve conflicts when a task is modified on one side and deleted on the other.
- `keep-newest': Compare timestamps and keep the more recent action
- `prefer-org': Always keep the Org version (don't delete if modified locally)
- `prefer-api': Always keep the TickTick version (don't delete if modified remotely)
- `ask': Prompt user to decide"
  :type '(choice (const :tag "Keep newest modification" keep-newest)
                 (const :tag "Prefer Org modifications" prefer-org)
                 (const :tag "Prefer TickTick modifications" prefer-api)
                 (const :tag "Ask user" ask))
  :group 'ticktick)

(defvar ticktick-token nil
  "Access token plist for accessing the TickTick API.")

(defvar ticktick-oauth-state nil
  "CSRF-prevention state for the OAuth flow.")

(defvar ticktick--sync-timer nil
  "Timer object for periodic syncing.")

;; --- Token persistence helpers -----------------------------------------------

(defun ticktick--ensure-dir ()
  "Check if `ticktick-dir` exists, otherwise create."
  (unless (file-directory-p ticktick-dir)
    (make-directory ticktick-dir t)))

(defun ticktick--save-token ()
  "Persist `ticktick-token` to `ticktick-token-file`."
  (when ticktick-token
    (ticktick--ensure-dir)
    (with-temp-file ticktick-token-file
      (insert (prin1-to-string ticktick-token)))))

(defun ticktick--load-token ()
  "Load token from `ticktick-token-file` into `ticktick-token`."
  (when (file-exists-p ticktick-token-file)
    (with-temp-buffer
      (insert-file-contents ticktick-token-file)
      (goto-char (point-min))
      (setq ticktick-token (read (current-buffer))))))

;; Load any existing token at startup
(ticktick--load-token)

;;; State tracking for deletion detection -------------------------------------

(defvar ticktick--sync-state nil
  "In-memory cache of the sync state.
This is a plist with keys:
  :last-sync-time  - timestamp of last successful sync
  :org-task-ids    - list of task IDs present in Org file during last sync
  :api-task-ids    - list of task IDs returned by API during last sync
  :task-project-map - alist mapping task IDs to project IDs
  :pending-deletes - list of deletions that failed and need retry
  :failed-operations - list of operations that failed with error details")

(defun ticktick--state-file-path ()
  "Return the path to the state file."
  (expand-file-name ".ticktick-state.el" ticktick-dir))

(defun ticktick--load-state ()
  "Load sync state from disk into `ticktick--sync-state`."
  (let ((state-file (ticktick--state-file-path)))
    (when (file-exists-p state-file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents state-file)
            (goto-char (point-min))
            (setq ticktick--sync-state (read (current-buffer))))
        (error
         (message "Warning: Could not load state file: %s" (error-message-string err))
         (setq ticktick--sync-state nil))))))

(defun ticktick--save-state ()
  "Persist `ticktick--sync-state` to disk."
  (when ticktick--sync-state
    (ticktick--ensure-dir)
    (let ((state-file (ticktick--state-file-path)))
      (condition-case err
          (with-temp-file state-file
            (insert (prin1-to-string ticktick--sync-state)))
        (error
         (message "Warning: Could not save state file: %s" (error-message-string err)))))))

(defun ticktick--collect-org-task-ids ()
  "Scan the org sync file and return a list of all TICKTICK_ID values."
  (let ((task-ids nil))
    (with-current-buffer (find-file-noselect ticktick-sync-file)
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (re-search-forward "^:TICKTICK_ID: \\(.+\\)$" nil t)
         (let ((id (match-string 1)))
           (when (and id (not (string-empty-p id)))
             (push id task-ids))))))
    (nreverse task-ids)))

(defun ticktick--collect-api-task-ids (all-projects)
  "Extract all task IDs from ALL-PROJECTS API response.
Returns a list of task IDs."
  (let ((task-ids nil))
    (dolist (project all-projects)
      (let* ((project-id (plist-get project :id))
             (project-data (ignore-errors
                            (ticktick-request "GET" (format "/open/v1/project/%s/data" project-id))))
             (tasks (when project-data (plist-get project-data :tasks))))
        (dolist (task tasks)
          (let ((id (plist-get task :id)))
            (when id (push id task-ids))))))
    (nreverse task-ids)))

(defun ticktick--collect-task-project-map ()
  "Scan the org file and return an alist of (TASK-ID . PROJECT-ID) pairs."
  (let ((map nil))
    (with-current-buffer (find-file-noselect ticktick-sync-file)
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (outline-next-heading)
         (when (= (org-current-level) 2)
           (let ((task-id (org-entry-get nil "TICKTICK_ID"))
                 (project-id (org-entry-get nil "TICKTICK_PROJECT_ID" t)))
             (when (and task-id (not (string-empty-p task-id))
                       project-id (not (string-empty-p project-id)))
               (push (cons task-id project-id) map)))))))
    (nreverse map)))

(defun ticktick--ensure-state-initialized ()
  "Initialize the state file if it doesn't exist or is empty."
  (unless ticktick--sync-state
    (ticktick--load-state))
  (unless ticktick--sync-state
    (setq ticktick--sync-state
          (list :last-sync-time nil
                :org-task-ids nil
                :api-task-ids nil
                :task-project-map nil
                :pending-deletes nil
                :failed-operations nil))
    (ticktick--save-state)))

;; Load state at startup
(ticktick--load-state)

;;; Deletion detection ---------------------------------------------------------

(defun ticktick--detect-org-deletions ()
  "Detect tasks that were deleted from Org since last sync.
Returns a list of deleted task IDs."
  (let* ((current-ids (ticktick--collect-org-task-ids))
         (previous-ids (plist-get ticktick--sync-state :org-task-ids)))
    (when previous-ids
      (cl-set-difference previous-ids current-ids :test #'string=))))

(defun ticktick--detect-api-deletions ()
  "Detect tasks that were deleted from TickTick since last sync.
Returns a list of deleted task IDs."
  (let* ((current-ids (plist-get ticktick--sync-state :api-task-ids))
         (previous-ids (plist-get ticktick--sync-state :api-task-ids)))
    ;; Note: current-ids will be updated after fetch, so we compare
    ;; the newly fetched IDs with the previous sync
    (when previous-ids
      (cl-set-difference previous-ids current-ids :test #'string=))))

(defun ticktick--find-task-by-id-in-org (task-id)
  "Find and return the position of task with TASK-ID in org file.
Returns nil if not found."
  (with-current-buffer (find-file-noselect ticktick-sync-file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (catch 'found
       (while (re-search-forward (format "^:TICKTICK_ID: %s$" (regexp-quote task-id)) nil t)
         (org-back-to-heading t)
         (throw 'found (point)))
       nil))))

(defun ticktick--get-cached-project-id (task-id)
  "Get the project ID for TASK-ID from the cached task-project map."
  (let ((map (plist-get ticktick--sync-state :task-project-map)))
    (cdr (assoc task-id map))))

(defun ticktick--get-task-info (task-id)
  "Get task information for TASK-ID from org file.
Returns a plist with :title, :project-id, and :position, or nil if not found."
  (let ((pos (ticktick--find-task-by-id-in-org task-id)))
    (when pos
      (with-current-buffer (find-file-noselect ticktick-sync-file)
        (org-with-wide-buffer
         (goto-char pos)
         (let ((el (org-element-at-point)))
           (list :title (org-element-property :raw-value el)
                 :project-id (org-entry-get nil "TICKTICK_PROJECT_ID" t)
                 :position pos)))))))

;;; Deletion execution ---------------------------------------------------------

(defun ticktick--delete-task-from-api (task-id)
  "Delete task with TASK-ID from TickTick API.
Returns t on success, nil on failure."
  (condition-case err
      (progn
        (ticktick-request "DELETE" (format "/open/v1/task/%s" task-id))
        (message "Deleted task %s from TickTick" task-id)
        t)
    (error
     (message "Failed to delete task %s from TickTick: %s"
              task-id (error-message-string err))
     ;; Add to failed operations for retry
     (let ((failed (plist-get ticktick--sync-state :failed-operations)))
       (push (list :type 'delete-from-api
                   :task-id task-id
                   :error (error-message-string err)
                   :timestamp (format-time-string "%FT%T%z"))
             failed)
       (plist-put ticktick--sync-state :failed-operations failed)
       (ticktick--save-state))
     nil)))

(defun ticktick--delete-task-from-org (task-id)
  "Delete task with TASK-ID from org file.
Behavior depends on `ticktick-delete-behavior'.
Returns t on success, nil if task not found."
  (let ((pos (ticktick--find-task-by-id-in-org task-id)))
    (if (not pos)
        (progn
          (message "Task %s not found in org file" task-id)
          nil)
      (with-current-buffer (find-file-noselect ticktick-sync-file)
        (org-with-wide-buffer
         (goto-char pos)
         (let ((task-info (ticktick--get-task-info task-id)))
           (cond
            ((eq ticktick-delete-behavior 'archive)
             (ticktick--archive-task task-id task-info))
            (t
             ;; Hard delete
             (delete-region (org-entry-beginning-position)
                           (org-entry-end-position))
             (message "Deleted task '%s' from org file"
                     (plist-get task-info :title)))))
         (save-buffer))
        t))))

(defun ticktick--archive-task (task-id task-info)
  "Archive task with TASK-ID and TASK-INFO to the configured archive location."
  (let ((task-title (plist-get task-info :title))
        (task-content (save-excursion
                        (goto-char (plist-get task-info :position))
                        (buffer-substring-no-properties
                         (org-entry-beginning-position)
                         (org-entry-end-position)))))
    (cond
     ((eq ticktick-archive-location 'separate-file)
      ;; Archive to separate file
      (ticktick--ensure-dir)
      (with-current-buffer (find-file-noselect ticktick-archive-file)
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert "* ARCHIVED " task-title "\n")
        (insert ":PROPERTIES:\n")
        (insert (format ":ARCHIVED_AT: [%s]\n"
                       (format-time-string "%F %a %H:%M")))
        (insert (format ":ARCHIVED_REASON: Deleted in TickTick\n"))
        (insert (format ":TICKTICK_ID: %s\n" task-id))
        (insert ":END:\n")
        ;; Copy the original task content (excluding the heading line)
        (let ((lines (split-string task-content "\n")))
          (dolist (line (cdr lines))
            (unless (string-match-p "^:PROPERTIES:" line)
              (insert line "\n"))))
        (save-buffer)))
     ((eq ticktick-archive-location 'archive-heading)
      ;; Archive under "Archived Tasks" heading in sync file
      (with-current-buffer (find-file-noselect ticktick-sync-file)
        (org-with-wide-buffer
         (goto-char (point-min))
         (unless (re-search-forward "^\\* Archived Tasks$" nil t)
           ;; Create archive heading if it doesn't exist
           (goto-char (point-max))
           (unless (bolp) (insert "\n"))
           (insert "* Archived Tasks\n"))
         (goto-char (match-end 0))
         (forward-line)
         (insert task-content)
         (insert "\n")
         ;; Add archive metadata
         (org-back-to-heading t)
         (org-set-property "ARCHIVED_AT"
                          (format-time-string "[%F %a %H:%M]"))
         (org-set-property "ARCHIVED_REASON" "Deleted in TickTick")
         (save-buffer)))))
    ;; Delete original task from sync file
    (with-current-buffer (find-file-noselect ticktick-sync-file)
      (org-with-wide-buffer
       (goto-char (plist-get task-info :position))
       (delete-region (org-entry-beginning-position)
                     (org-entry-end-position))
       (save-buffer)))
    (message "Archived task '%s'" task-title)))

(defun ticktick--confirm-deletion-p (task-id direction)
  "Ask user to confirm deletion of task with TASK-ID.
DIRECTION is either 'from-org or 'from-api indicating where the task is being deleted from.
Returns t if user confirms, nil otherwise."
  (cond
   ((eq ticktick-delete-behavior 'sync-only)
    nil)
   ((eq ticktick-delete-behavior 'delete)
    t)
   ((or (eq ticktick-delete-behavior 'ask)
        ticktick-confirm-deletions)
    (let* ((task-info (ticktick--get-task-info task-id))
           (task-title (if task-info
                          (plist-get task-info :title)
                        task-id))
           (prompt (if (eq direction 'from-org)
                      (format "Task '%s' was deleted locally. Delete from TickTick? " task-title)
                    (format "Task '%s' was deleted remotely. Delete from Org? " task-title))))
      (y-or-n-p prompt)))
   (t t)))

;;; Deletion handlers ----------------------------------------------------------

(defun ticktick--handle-org-deletions (deleted-ids)
  "Handle tasks that were deleted from Org (in DELETED-IDS).
Deletes them from TickTick API if user confirms."
  (when deleted-ids
    (message "Detected %d task(s) deleted from Org" (length deleted-ids))
    (dolist (task-id deleted-ids)
      (when (ticktick--confirm-deletion-p task-id 'from-org)
        (ticktick--delete-task-from-api task-id)))))

(defun ticktick--handle-api-deletions (deleted-ids)
  "Handle tasks that were deleted from TickTick API (in DELETED-IDS).
Deletes or archives them in Org if user confirms."
  (when deleted-ids
    (message "Detected %d task(s) deleted from TickTick" (length deleted-ids))
    (dolist (task-id deleted-ids)
      (when (ticktick--confirm-deletion-p task-id 'from-api)
        (ticktick--delete-task-from-org task-id)))))

;;; Authorization functions ----------------------------------------------------

(defun ticktick--authorization-header ()
  "Create basic authentication header for TickTick API."
  (concat "Basic "
          (base64-encode-string
           (concat ticktick-client-id ":" ticktick-client-secret) t)))

(defun ticktick--make-token-request (form-params)
  "Make a token request with FORM-PARAMS and return the response data."
  (let* ((form-data
          (mapconcat
           (lambda (kv)
             (format "%s=%s"
                     (url-hexify-string (car kv))
                     (url-hexify-string (format "%s" (cdr kv)))))
           form-params
           "&"))
         (authorization (ticktick--authorization-header))
         (response-data nil))
    (request "https://ticktick.com/oauth/token"
      :type "POST"
      :headers `(("Authorization" . ,authorization)
                 ("Content-Type" . "application/x-www-form-urlencoded"))
      :data form-data
      :parser (lambda ()
                (let ((json-object-type 'plist)
                      (json-array-type 'list))
                  (json-read)))
      :sync t
      :success (cl-function
                (lambda (&key data &allow-other-keys)
                  (setq response-data data)))
      :error (cl-function
              (lambda (&key response error-thrown &allow-other-keys)
                (message "Token request failed: %s (HTTP %s)"
                         (or error-thrown "unknown error")
                         (and response (request-response-status-code response)))
                (setq response-data nil))))
    (when (and response-data (plist-get response-data :access_token))
      ;; capture the updated plist
      (setq response-data
            (plist-put response-data :created_at (float-time))))
    response-data))


(defun ticktick--exchange-code-for-token (code)
  "Exchange the authorization CODE for an access token."
  (ticktick--make-token-request
   `(("grant_type" . "authorization_code")
     ("code" . ,code)
     ("redirect_uri" . ,ticktick-redirect-uri)
     ("scope" . ,ticktick-auth-scopes))))

(defun ticktick--start-callback-server ()
  "Start the local OAuth callback server if not already running."
  (setq httpd-port ticktick-httpd-port)
  (unless (httpd-running-p)
    (httpd-start)))

;; The servlet name determines the path: /ticktick-callback
(defservlet ticktick-callback text/plain (_path query)
  "Handle the TickTick OAuth redirect."
  (let ((code  (cadr (assoc "code" query)))
        (state (cadr (assoc "state" query))))
    (cond
     ((not (and code state))
      (insert "Authentication failed: missing code/state."))
     ((and ticktick-oauth-state (not (string= state ticktick-oauth-state)))
      (insert "Authentication failed: invalid state."))
     (t
      (let ((tok (ticktick--exchange-code-for-token code)))
        (if tok
            (progn
              (setq ticktick-token tok)
              (ticktick--save-token)
              (insert "Authentication successful! You can close this window.")
              (message "TickTick: authenticated successfully."))
          (insert "Authentication failed while exchanging code.")
          (message "TickTick: token exchange failed.")))))))

(defun ticktick-debug-oauth ()
  "Debug OAuth configuration and connection."
  (interactive)
  (message "=== TickTick OAuth Debug Info ===")
  (message "Client ID: %s" (if (string-empty-p ticktick-client-id) "NOT SET" "SET"))
  (message "Client Secret: %s" (if (string-empty-p ticktick-client-secret) "NOT SET" "SET"))
  (message "Redirect URI: %s" ticktick-redirect-uri)
  (message "Auth Scopes: %s" ticktick-auth-scopes)
  (message "Token file: %s" ticktick-token-file)
  (message "Token exists: %s" (if (and ticktick-token (plist-get ticktick-token :access_token)) "YES" "NO"))
  (when ticktick-token
    (message "Token expires: %s" (if (ticktick-token-expired-p ticktick-token) "EXPIRED" "VALID")))
  (message "Server running: %s" (if (httpd-running-p) "YES" "NO"))
  (message "Server port: %d" ticktick-httpd-port))

;;;###autoload
(defun ticktick-authorize ()
  "Authorize with TickTick and obtain an access token via local callback.
Starts local server, requests consent through browser, then captures redirect."
  (interactive)
  (unless (and (stringp ticktick-client-id) (not (string-empty-p ticktick-client-id))
               (stringp ticktick-client-secret) (not (string-empty-p ticktick-client-secret)))
    (user-error "Ticktick-client-id and ticktick-client-secret must be set"))
  (ticktick--start-callback-server)
  (setq ticktick-oauth-state (format "%06x" (random (expt 16 6))))
  (let* ((auth-url (concat "https://ticktick.com/oauth/authorize?"
                           (url-build-query-string
                            `(("client_id" ,ticktick-client-id)
                              ("response_type" "code")
                              ("redirect_uri" ,ticktick-redirect-uri)
                              ("scope" ,ticktick-auth-scopes)
                              ("state" ,ticktick-oauth-state))))))
    (browse-url auth-url)
    (message "TickTick: opened browser for OAuth. Waiting for http://localhost:%d/ticktick-callback ..." ticktick-httpd-port)))

;;; Manual fallback (optional): if you ever want to paste a code directly
(defun ticktick-authorize-manual (code)
  "Manually exchange CODE for an access token (fallback)."
  (interactive "sPaste ?code= value from redirect URL: ")
  (let ((tok (ticktick--exchange-code-for-token code)))
    (if tok
        (progn
          (setq ticktick-token tok)
          (ticktick--save-token)
          (message "Authorization successful!"))
      (user-error "Failed to obtain access token"))))

;;; Token maintenance ----------------------------------------------------------

;;;###autoload
(defun ticktick-refresh-token ()
  "Refresh the OAuth2 token."
  (interactive)
  (when ticktick-token
    (let* ((refresh-token (plist-get ticktick-token :refresh_token))
           (response-data (ticktick--make-token-request
                          `(("grant_type" . "refresh_token")
                            ("refresh_token" . ,refresh-token)
                            ("redirect_uri" . ,ticktick-redirect-uri)
                            ("scope" . ,ticktick-auth-scopes)))))
      (if response-data
          (progn
            (setq ticktick-token response-data)
            (ticktick--save-token)
            (message "Token refreshed!"))
        (message "Failed to refresh token.")))))

(defun ticktick-token-expired-p (token)
  "Check if TOKEN has expired."
  (let ((expires-in (plist-get token :expires_in))
        (created-at (plist-get token :created_at)))
    (if (and expires-in created-at)
        (> (float-time) (+ created-at expires-in -30))
      nil)))

(defun ticktick-ensure-token ()
  "Ensure we have a valid access token."
  (ticktick--load-token)
  (unless (and ticktick-token
               (plist-get ticktick-token :access_token)
               (not (ticktick-token-expired-p ticktick-token)))
    (ticktick-refresh-token)))

;;; Core request ---------------------------------------------------------------

(defun ticktick--parse-json-maybe ()
  "Parse current buffer as JSON if non-empty; otherwise return nil."
  (goto-char (point-min))
  (let ((json-object-type 'plist)
        (json-array-type 'list)
        (json-false :false))
    (if (zerop (buffer-size))
        nil
      (condition-case _ (json-read)
        (json-error nil)))))

(defun ticktick-request (method endpoint &optional data)
  "Send a request to the TickTick API.
METHOD is the HTTP method to use (GET, POST, etc.).
ENDPOINT is the API endpoint to request.
DATA is the optional request body data."
  (ticktick-ensure-token)
  (let* ((url (concat "https://api.ticktick.com" endpoint))
         (access-token (plist-get ticktick-token :access_token))
         (headers `(("Authorization" . ,(concat "Bearer " access-token))
                    ("Content-Type" . "application/json")))
         (json-data (and data (json-encode data)))
         (response-data nil))
    (request url
      :type method
      :headers headers
      :data json-data
      :parser #'ticktick--parse-json-maybe
      :sync t
      :success (cl-function
                (lambda (&key data response &allow-other-keys)
                  (let ((status (request-response-status-code response)))
                    (cond
                     ((and (>= status 200) (< status 300))
                      (setq response-data data))
                     ((= status 401)
                      (ticktick-refresh-token)
                      (setq response-data (ticktick-request method endpoint data)))
                     (t (error "HTTP Error %s" status))))))
      :error (cl-function
              (lambda (&key response error-thrown &allow-other-keys)
                (let ((status (and response (request-response-status-code response))))
                  (cond
                   ((= status 401)
                    (ticktick-refresh-token)
                    (setq response-data (ticktick-request method endpoint data)))
                   (t
                    (message "Request failed: %s"
                             (or (and response (request-response-data response))
                                 error-thrown))
                    (setq response-data nil)))))))
    response-data))

;;; Org conversion helpers -----------------------------------------------------

(defun ticktick--task-to-heading (task)
  "Convert TASK plist to an org heading string.
Content lines starting with \"*\" or \"#+\" are escaped so they are not
read back as Org syntax."
  (let ((id (plist-get task :id))
        (title (plist-get task :title))
        (status (plist-get task :status))
        (priority (plist-get task :priority))
        (due (plist-get task :dueDate))
        (etag (plist-get task :etag))
        (content (plist-get task :content))
        (tags (plist-get task :tags)))
    (string-join
     (delq nil
           (list
            (format "** %s%s %s%s"
                    (if (= status 2) "DONE" "TODO")
                    (pcase priority (5 " [#A]") (3 " [#B]") (1 " [#C]") (_ ""))
                    title
                    (if (and tags (> (length tags) 0))
                        (concat " :" (mapconcat #'identity tags ":") ":")
                      ""))
            (when due
              (format "DEADLINE: <%s>" (format-time-string "%F %a" (date-to-time due))))
            ":PROPERTIES:"
            (format ":TICKTICK_ID: %s" id)
            (format ":TICKTICK_ETAG: %s" (or etag ""))
            ":END:"
            (when content
              (org-escape-code-in-string (string-trim content)))))
     "\n")))

(defun ticktick--heading-to-task ()
  "Convert org heading at point to a TickTick task plist.
Org escaping is removed from the content."
  (let* ((el (org-element-at-point))
         (title (org-element-property :title el))
         (todo (org-element-property :todo-type el))
         (priority (org-element-property :priority el))
         (deadline (org-element-property :deadline el))
         (tags (org-element-property :tags el))
         (id (org-entry-get nil "TICKTICK_ID"))
         (content
          (save-excursion
            (save-restriction
              (org-narrow-to-subtree)
              (goto-char (point-min))
              (forward-line)
              (while (looking-at org-planning-line-re)
                (forward-line))
              (when (looking-at ":PROPERTIES:")
                (re-search-forward "^:END:" nil t)
                (forward-line))
              (org-unescape-code-in-string
               (string-trim
                (buffer-substring-no-properties (point) (point-max))))))))
    `(("id" . ,id)
      ("title" . ,title)
      ("status" . ,(if (eq todo 'done) 2 0))
      ("priority" . ,(pcase priority (?A 5) (?B 3) (?C 1) (_ 0)))
      ("dueDate" . ,(when deadline
                      (format-time-string "%FT%T+0000"
                                          (org-timestamp-to-time deadline))))
      ("tags" . ,(when tags (vconcat tags)))
      ("content" . ,content))))

(defun ticktick--subtree-body-for-hash ()
  "Return a stable string of the current subtree, with volatile props removed."
  (let* ((raw (buffer-substring-no-properties
               (org-entry-beginning-position) (org-entry-end-position))))
    (with-temp-buffer
      (insert raw)
      (goto-char (point-min))
      ;; Remove property drawers entirely
      (while (re-search-forward "^:PROPERTIES:\n\\(?:.*\n\\)*?:END:\n?" nil t)
        (replace-match "" nil nil))
      ;; Remove any stray volatile property lines (if not in a drawer)
      (goto-char (point-min))
      (while (re-search-forward
              "^:\\(LAST_SYNCED\\|SYNC_CACHE\\|TICKTICK_ETAG\\|TICKTICK_ID\\):.*\n" nil t)
        (replace-match "" nil nil))
      (buffer-string))))

(defun ticktick--should-sync-p ()
  "Return non-nil if the current subtree changed since last sync."
  (let* ((etag   (org-entry-get nil "TICKTICK_ETAG"))
         (cached (org-entry-get nil "SYNC_CACHE"))
         (digest (secure-hash 'sha1 (ticktick--subtree-body-for-hash))))
    (or (not etag) (not (and cached (string= cached digest))))))

(defun ticktick--update-sync-meta ()
  "Set sync hash and time on current subtree."
  (let* ((digest (secure-hash 'sha1 (ticktick--subtree-body-for-hash))))
    (org-set-property "LAST_SYNCED" (format-time-string "%FT%T%z"))
    (org-set-property "SYNC_CACHE"  digest)))

;;; Sync functions -------------------------------------------------------------

(defun ticktick--create-project-heading (project-title project-id)
  "Insert a new Org heading for PROJECT-TITLE with PROJECT-ID.
Return the buffer position at the start of the heading."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))            ; ensure we start on a fresh line
  (let ((start (point)))                   ; this will be the heading's start
    (insert (format "* %s\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: %s\n:END:\n"
                    project-title project-id))
    start))


(defun ticktick--sync-task (task project-pos)
  "Sync a single TASK under PROJECT-POS, updating or creating as needed."
  (let* ((id (plist-get task :id))
         (etag (plist-get task :etag))
         (existing-pos (ticktick--find-task-under-project project-pos id)))
    (if existing-pos
        (save-excursion
          (goto-char existing-pos)
          (let ((existing-etag (org-entry-get nil "TICKTICK_ETAG")))
            (unless (string= existing-etag etag)
              (delete-region (org-entry-beginning-position)
                             (org-entry-end-position))
              (insert (ticktick--task-to-heading task))
              (ticktick--update-sync-meta))))
      (save-excursion
        (goto-char project-pos)
        (outline-next-heading)
        (insert (ticktick--task-to-heading task) "\n")
        (ticktick--update-sync-meta)))))

(defun ticktick--sync-project (project)
  "Sync a single PROJECT with all its tasks."
  (let* ((project-id (plist-get project :id))
         (project-title (plist-get project :name))
         (project-heading-re (format "^\\* %s$" (regexp-quote project-title)))
         (project-pos (save-excursion
                        (goto-char (point-min))
                        (when (re-search-forward project-heading-re nil t)
                          (match-beginning 0)))))
    (unless project-pos
      (setq project-pos (ticktick--create-project-heading project-title project-id)))
    (goto-char project-pos)
    (outline-show-subtree)
    (let* ((project-data (ticktick-request "GET" (format "/open/v1/project/%s/data" project-id)))
           (tasks (plist-get project-data :tasks)))
      (dolist (task tasks)
        (ticktick--sync-task task project-pos)))))

(defun ticktick--update-task (task project-id id)
  "Update existing task with TASK data, PROJECT-ID, and ID."
  (ticktick-request "POST" (format "/open/v1/task/%s" id)
                    (append task `(("projectId" . ,project-id))))
  (ticktick--update-sync-meta)
  (message "Updated: %s" (alist-get "title" task)))

(defun ticktick--create-task (task project-id)
  "Create new task with TASK data and PROJECT-ID."
  (let ((resp (ticktick-request "POST" "/open/v1/task"
                                (append task `(("projectId" . ,project-id))))))
    (when resp
      (org-set-property "TICKTICK_ID" (plist-get resp :id))
      (org-set-property "TICKTICK_ETAG" (plist-get resp :etag))
      (ticktick--update-sync-meta)
      (message "Created: %s" (plist-get resp :title)))))

(defun ticktick--find-task-under-project (project-heading id)
  "Return position of task heading with ID under PROJECT-HEADING."
  (save-excursion
    (goto-char project-heading)
    (catch 'found
      (org-map-entries
       (lambda ()
         (when (string= (org-entry-get nil "TICKTICK_ID") id)
           (throw 'found (point))))
       nil 'tree)
      nil)))

(defun ticktick-fetch-to-org ()
  "Fetch all tasks from TickTick and update org file without duplicating.
Also detects and handles tasks deleted from TickTick since last sync."
  (interactive)
  ;; Initialize state tracking
  (ticktick--ensure-state-initialized)

  ;; Fetch projects and tasks from API
  (let* ((inbox-project `(:id "inbox" :name "Inbox"))
         (projects (ticktick-request "GET" "/open/v1/project"))
         (all-projects (cons inbox-project projects)))

    ;; Collect current API task IDs
    (let ((current-api-ids (ticktick--collect-api-task-ids all-projects))
          (previous-api-ids (plist-get ticktick--sync-state :api-task-ids)))

      ;; Detect deletions from API (tasks that existed before but are gone now)
      (when previous-api-ids
        (let ((deleted-ids (cl-set-difference previous-api-ids current-api-ids :test #'string=)))
          (when deleted-ids
            (ticktick--handle-api-deletions deleted-ids))))

      ;; Sync all projects and tasks
      (with-current-buffer (find-file-noselect ticktick-sync-file)
        (org-with-wide-buffer
         (dolist (project all-projects)
           (ticktick--sync-project project))
         (save-buffer)))

      ;; Update state with current API task IDs
      (plist-put ticktick--sync-state :api-task-ids current-api-ids)
      (plist-put ticktick--sync-state :last-sync-time (format-time-string "%FT%T%z"))
      (ticktick--save-state))))

(defun ticktick-push-from-org ()
  "Push all updated org tasks back to TickTick.
Also detects and handles tasks deleted from Org since last sync."
  (interactive)
  ;; Initialize state tracking
  (ticktick--ensure-state-initialized)

  ;; Detect deletions from Org (tasks that existed before but are gone now)
  (let ((deleted-ids (ticktick--detect-org-deletions)))
    (when deleted-ids
      (ticktick--handle-org-deletions deleted-ids)))

  ;; Push normal updates and new tasks
  (with-current-buffer (find-file-noselect ticktick-sync-file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (outline-next-heading)
       (when (and (= (org-current-level) 2)
                  (not (org-entry-get nil "TICKTICK_PROJECT_ID")))
         (when (ticktick--should-sync-p)
           (let* ((task (ticktick--heading-to-task))
                  (project-id (org-entry-get nil "TICKTICK_PROJECT_ID" t))
                  (id (org-entry-get nil "TICKTICK_ID")))
             (if (and id (not (string-empty-p id)))
                 (ticktick--update-task task project-id id)
               (ticktick--create-task task project-id))))))
     (save-buffer)))

  ;; Update state with current Org task IDs and project map
  (let ((current-org-ids (ticktick--collect-org-task-ids))
        (task-project-map (ticktick--collect-task-project-map)))
    (plist-put ticktick--sync-state :org-task-ids current-org-ids)
    (plist-put ticktick--sync-state :task-project-map task-project-map)
    (plist-put ticktick--sync-state :last-sync-time (format-time-string "%FT%T%z"))
    (ticktick--save-state)))


(defun ticktick-sync ()
  "Two-way sync: push local changes first, then fetch remote updates."
  (interactive)
  (ticktick-push-from-org)
  (sit-for 1)
  (ticktick-fetch-to-org))

(defun ticktick--autosync ()
  "Autosync if enabled."
  (when ticktick-autosync
    (when (file-exists-p ticktick-sync-file)
      (ignore-errors (ticktick-sync)))))

(defun ticktick--setup-sync-timer ()
  "Set up or tear down the sync timer based on `ticktick-sync-interval'."
  (when ticktick--sync-timer
    (cancel-timer ticktick--sync-timer)
    (setq ticktick--sync-timer nil))
  (when (and ticktick-sync-interval
             (numberp ticktick-sync-interval)
             (> ticktick-sync-interval 0))
    (setq ticktick--sync-timer
          (run-at-time ticktick-sync-interval
                       (* ticktick-sync-interval 60)
                       #'ticktick--timer-sync))))

(defun ticktick--timer-sync ()
  "Sync function called by timer."
  (when (file-exists-p ticktick-sync-file)
    (ignore-errors (ticktick-sync))))

;;;###autoload
(defun ticktick-toggle-sync-timer ()
  "Toggle automatic timer-based syncing on/off."
  (interactive)
  (if ticktick--sync-timer
      (progn
        (cancel-timer ticktick--sync-timer)
        (setq ticktick--sync-timer nil)
        (message "TickTick timer sync disabled"))
    (if (and ticktick-sync-interval
             (numberp ticktick-sync-interval)
             (> ticktick-sync-interval 0))
        (progn
          (ticktick--setup-sync-timer)
          (message "TickTick timer sync enabled (every %d minutes)" ticktick-sync-interval))
      (message "Set ticktick-sync-interval to enable timer sync"))))


;; Run autosync when frame loses focus

(defun ticktick--maybe-autosync-on-focus-change (&rest _)
  "Trigger autosync when the selected frame loses focus."
  (when (and (fboundp 'frame-focus-state)
             (not (frame-focus-state (selected-frame))))
    (run-with-idle-timer 0 nil #'ticktick--autosync)))

;;;###autoload
(defun ticktick-enable-autosync-on-blur ()
  "Enable automatic synchronization when Emacs loses window focus."
  (if (boundp 'after-focus-change-function)
      (add-function :after after-focus-change-function
                    #'ticktick--maybe-autosync-on-focus-change)
    (with-suppressed-warnings ((obsolete focus-out-hook))
      (add-hook 'focus-out-hook #'ticktick--autosync))))

;;;###autoload
(defun ticktick-disable-autosync-on-blur ()
  "Disable automatic synchronization on window focus loss."
  (if (boundp 'after-focus-change-function)
      (remove-function after-focus-change-function
                       #'ticktick--maybe-autosync-on-focus-change)
    (with-suppressed-warnings ((obsolete focus-out-hook))
      (remove-hook 'focus-out-hook #'ticktick--autosync))))

;;; Commands for deletion management --------------------------------------

;;;###autoload
(defun ticktick-delete-task-at-point ()
  "Delete the TickTick task at point.
This will delete the task both locally and from TickTick after confirmation.
Respects the `ticktick-delete-behavior' setting."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "This command must be run in an org-mode buffer"))
  (let ((task-id (org-entry-get nil "TICKTICK_ID")))
    (unless task-id
      (user-error "No TickTick task at point"))
    (let ((task-info (ticktick--get-task-info task-id)))
      (when (or (eq ticktick-delete-behavior 'delete)
                (y-or-n-p (format "Delete task '%s' from both Org and TickTick? "
                                 (plist-get task-info :title))))
        ;; Delete from API first
        (when (ticktick--delete-task-from-api task-id)
          ;; Then delete from Org
          (delete-region (org-entry-beginning-position)
                        (org-entry-end-position))
          (save-buffer)
          (message "Task deleted successfully"))))))

;;;###autoload
(defun ticktick-retry-failed-deletions ()
  "Retry all failed deletion operations from the state file."
  (interactive)
  (ticktick--load-state)
  (let ((failed (plist-get ticktick--sync-state :failed-operations)))
    (if (not failed)
        (message "No failed operations to retry")
      (message "Retrying %d failed operation(s)..." (length failed))
      (let ((retry-count 0)
            (success-count 0))
        (dolist (op failed)
          (setq retry-count (1+ retry-count))
          (let ((op-type (plist-get op :type))
                (task-id (plist-get op :task-id)))
            (condition-case err
                (progn
                  (cond
                   ((eq op-type 'delete-from-api)
                    (when (ticktick--delete-task-from-api task-id)
                      (setq success-count (1+ success-count))
                      (setq failed (delq op failed))))
                   ((eq op-type 'delete-from-org)
                    (when (ticktick--delete-task-from-org task-id)
                      (setq success-count (1+ success-count))
                      (setq failed (delq op failed))))))
              (error
               (message "Failed to retry operation for task %s: %s"
                       task-id (error-message-string err))))))
        (plist-put ticktick--sync-state :failed-operations failed)
        (ticktick--save-state)
        (message "Retry complete: %d/%d operations succeeded"
                success-count retry-count)))))

;;;###autoload
(defun ticktick-show-sync-state ()
  "Display the current sync state in a temporary buffer."
  (interactive)
  (ticktick--load-state)
  (let ((buf (get-buffer-create "*TickTick Sync State*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert "TickTick Synchronization State\n")
      (insert "===============================\n\n")
      (insert (format "Last sync time: %s\n"
                     (or (plist-get ticktick--sync-state :last-sync-time) "Never")))
      (insert (format "Org task count: %d\n"
                     (length (plist-get ticktick--sync-state :org-task-ids))))
      (insert (format "API task count: %d\n"
                     (length (plist-get ticktick--sync-state :api-task-ids))))
      (insert (format "Failed operations: %d\n"
                     (length (plist-get ticktick--sync-state :failed-operations))))
      (insert "\n")
      (when (plist-get ticktick--sync-state :failed-operations)
        (insert "Failed Operations:\n")
        (insert "------------------\n")
        (dolist (op (plist-get ticktick--sync-state :failed-operations))
          (insert (format "  Type: %s\n" (plist-get op :type)))
          (insert (format "  Task ID: %s\n" (plist-get op :task-id)))
          (insert (format "  Error: %s\n" (plist-get op :error)))
          (insert (format "  Timestamp: %s\n\n" (plist-get op :timestamp)))))
      (insert "\nState file location: ")
      (insert (ticktick--state-file-path))
      (goto-char (point-min))
      (special-mode))
    (display-buffer buf)))

;;;###autoload
(defun ticktick-clear-sync-state ()
  "Clear the sync state file.
This will reset deletion tracking, requiring a fresh sync.
Use this if the state file becomes corrupted."
  (interactive)
  (when (y-or-n-p "Clear sync state? This will reset deletion tracking. ")
    (setq ticktick--sync-state nil)
    (let ((state-file (ticktick--state-file-path)))
      (when (file-exists-p state-file)
        (delete-file state-file)))
    (message "Sync state cleared. Run ticktick-sync to rebuild state.")))

(provide 'ticktick)
;;; ticktick.el ends here
