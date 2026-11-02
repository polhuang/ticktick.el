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
;;    `ticktick-client-secret' also accepts a function of no arguments,
;;    to fetch it on demand from auth-source.  See the README.
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
;; - `ticktick-sync-file': Default Org file for tasks
;; - `ticktick-project-files': Optional project ID to Org file mappings
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
  "TickTick client secret, or a function of no arguments returning it."
  :type '(choice (string :tag "Secret")
                 (function :tag "Function returning the secret"))
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
  "Default Org destination for projects absent from `ticktick-project-files'."
  :type 'file
  :group 'ticktick)


(defcustom ticktick-project-files nil
  "Alist mapping TickTick project IDs to destination Org files.
Use `inbox' for Inbox.  Unmapped projects use `ticktick-sync-file'.
Relative paths are resolved under `ticktick-dir'.  Files and parent directories
are created when tasks are written.  Existing tasks are relocated on sync,
retaining their IDs and unrelated properties.  Each file uses project headings."
  :type '(alist :key-type (string :tag "Project ID")
                :value-type (file :tag "Org file"))
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
- `separate-file': Archive to the file specified by
  `ticktick-archive-file'
- `archive-heading': Archive under an \"Archived Tasks\" heading
  in the sync file"
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
  "Legacy deletion-conflict preference retained for configuration compatibility.
The reconciler always records delete-versus-edit conflicts for explicit review.
Deletion timestamps are unavailable, so keep-newest cannot be determined safely."
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

(defvar ticktick--sync-in-progress nil
  "Non-nil while synchronization is running in this Emacs.")

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

(defconst ticktick--state-version 3
  "Current synchronization state schema version.")

(defun ticktick--migrate-state (state)
  "Return STATE upgraded without inventing per-task baselines."
  (unless (and (proper-list-p state) (cl-evenp (length state))
               (cl-loop for (key _value) on state by #'cddr always (keywordp key)))
    (error "Invalid TickTick state"))
  (when (> (or (plist-get state :version) 1) ticktick--state-version)
    (error "TickTick state was written by a newer package"))
  (dolist (key '(:baselines :pending-operations :conflicts :sync-files :file-moves))
    (unless (plist-member state key)
      (setq state (plist-put state key nil))))
  (plist-put state :version ticktick--state-version))

(defun ticktick--load-state ()
  "Load and migrate sync state; signal on corruption rather than losing history."
  (let ((state-file (ticktick--state-file-path)))
    (when (file-exists-p state-file)
      (with-temp-buffer
        (insert-file-contents state-file)
        (setq ticktick--sync-state
              (ticktick--migrate-state (read (current-buffer))))))))

(defun ticktick--save-state ()
  "Atomically persist state, signaling failure before subsequent mutations."
  (when ticktick--sync-state
    (ticktick--ensure-dir)
    (let ((temporary (make-temp-file (expand-file-name ".state-" ticktick-dir))))
      (unwind-protect
          (progn
            (with-temp-file temporary
              (insert (prin1-to-string ticktick--sync-state)))
            (set-file-modes temporary #o600)
            (rename-file temporary (ticktick--state-file-path) t))
        (when (file-exists-p temporary) (delete-file temporary))))))

(defun ticktick--collect-org-task-ids ()
  "Return active TickTick task IDs across the configured Org files."
  (delq nil (mapcar (lambda (record) (plist-get record :id))
                   (ticktick--collect-local-records))))

(defun ticktick--fetch-project-data (project)
  "Fetch PROJECT data, signaling an error if the task list is unavailable."
  (let* ((project-id (plist-get project :id))
         (data (ticktick-request
                "GET" (format "/open/v1/project/%s/data" project-id))))
    (unless (and (listp data) (plist-member data :tasks)
                 (listp (plist-get data :tasks)))
      (error "TickTick: missing task list for project %s" project-id))
    data))

(defun ticktick--collect-api-task-ids (all-project-data)
  "Extract task IDs from the successfully fetched ALL-PROJECT-DATA."
  (let (task-ids)
    (dolist (data all-project-data)
      (dolist (task (plist-get data :tasks))
        (let ((id (plist-get task :id)))
          (unless (and (stringp id) (not (string-empty-p id)))
            (error "TickTick: task without an ID in project data"))
          (push id task-ids))))
    (nreverse task-ids)))

(defun ticktick--collect-task-project-map ()
  "Return active task IDs and project IDs across configured Org files."
  (cl-loop for record in (ticktick--collect-local-records)
           for id = (plist-get record :id)
           when id collect (cons id (plist-get (plist-get record :snapshot) :project-id))))

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
    (ticktick--save-state))
  (setq ticktick--sync-state (ticktick--migrate-state ticktick--sync-state)))

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
  "Return task TASK-ID's position; use `ticktick--get-task-info' for its file."
  (plist-get (ticktick--local-record task-id) :position))

(defun ticktick--get-cached-project-id (task-id)
  "Get the project ID for TASK-ID from the cached task-project map."
  (let ((map (plist-get ticktick--sync-state :task-project-map)))
    (cdr (assoc task-id map))))

(defun ticktick--get-task-info (task-id)
  "Return TASK-ID's :title, :project-id, :position, and :file."
  (let ((record (ticktick--local-record task-id)))
    (when record
      (list :title (plist-get (plist-get record :snapshot) :title)
            :project-id (plist-get (plist-get record :snapshot) :project-id)
            :position (plist-get record :position) :file (plist-get record :file)))))

;;; Deletion execution ---------------------------------------------------------

(defun ticktick--delete-task-from-api (task-id &optional project-id)
  "Delete TASK-ID from PROJECT-ID, looking up its project if omitted.
Returns t on success, nil on failure."
  (condition-case err
      (progn
        (setq project-id (or project-id
                             (plist-get (ticktick--baseline task-id) :project-id)
                             (ticktick--get-cached-project-id task-id)
                             (plist-get (ticktick--get-task-info task-id) :project-id)))
        (unless project-id (error "Unknown project for task %s" task-id))
        (ticktick-request "DELETE" (format "/open/v1/project/%s/task/%s" project-id task-id))
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
       (setq ticktick--sync-state (plist-put ticktick--sync-state :failed-operations failed))
       (ticktick--save-state))
     nil)))

(defun ticktick--delete-task-from-org (task-id)
  "Remove or archive TASK-ID from its actual Org file."
  (when (ticktick--local-record task-id)
    (ticktick--remove-local-task task-id)
    t))

(defun ticktick--confirm-deletion-p (task-id direction)
  "Ask user to confirm deletion of task with TASK-ID.
DIRECTION is either `from-org' or `from-api', indicating which side
originally lost the task.
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

(defun ticktick--client-secret ()
  "Return `ticktick-client-secret' as a string, calling it if it is a function."
  (or (if (functionp ticktick-client-secret)
          (funcall ticktick-client-secret)
        ticktick-client-secret)
      ""))

(defun ticktick--authorization-header ()
  "Create basic authentication header for TickTick API."
  (concat "Basic "
          (base64-encode-string
           (concat ticktick-client-id ":" (ticktick--client-secret)) t)))

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
  (message "Client Secret: %s"
           (if (string-empty-p (ticktick--client-secret)) "NOT SET" "SET"))
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
               (not (string-empty-p (ticktick--client-secret))))
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
  "Parse JSON, preserving the distinction between empty task arrays and objects.
Return nil for an empty response; signal on malformed or trailing JSON."
  (goto-char (point-min))
  (skip-chars-forward " \t\r\n")
  (unless (eobp)
    (let* ((json-object-type 'plist)
           (json-array-type 'vector)
           (json-false :false)
           (value (json-read)))
      (skip-chars-forward " \t\r\n")
      (unless (eobp) (error "Trailing data in TickTick JSON response"))
      (when (and (listp value) (plist-member value :tasks)
                 (not (vectorp (plist-get value :tasks))))
        (error "TickTick task list must be an array"))
      (cl-labels ((lists (item)
                    (cond ((vectorp item) (mapcar #'lists (append item nil)))
                          ((consp item) (cons (lists (car item)) (lists (cdr item))))
                          (t item))))
        (lists value)))))

(define-error 'ticktick-api-error "TickTick API request failed")

(defun ticktick-request (method endpoint &optional data)
  "Send METHOD to TickTick ENDPOINT with optional body DATA.
Return parsed response data, or nil for a successful empty response.
Signal an error on HTTP, transport, or JSON parsing failure.  Retry an
unauthorized request once after refreshing the token."
  (ticktick-ensure-token)
  (let ((url (concat "https://api.ticktick.com" endpoint))
        (json-data (and data (json-encode data)))
        response-data succeeded status failure)
    ;; Record callback results and signal outside the callbacks: request.el
    ;; may catch errors signaled inside a callback.
    (dotimes (attempt 2)
      (unless succeeded
        (setq status nil failure nil)
        (request url
          :type method
          :headers `(("Authorization" . ,(concat "Bearer " (plist-get ticktick-token :access_token)))
                     ("Content-Type" . "application/json"))
          :data json-data
          :parser (lambda ()
                    (when (and (string= method "GET") (zerop (buffer-size)))
                      (error "Empty response to TickTick GET request"))
                    (when (equal endpoint "/open/v1/project")
                      (goto-char (point-min))
                      (skip-chars-forward " \t\r\n")
                      (unless (eq (char-after) ?\[)
                        (error "TickTick project list must be an array")))
                    (ticktick--parse-json-maybe))
          :sync t
          :success (cl-function
                    (lambda (&key data response &allow-other-keys)
                      (setq status (request-response-status-code response))
                      (when (and (numberp status) (<= 200 status) (< status 300))
                        (setq response-data data succeeded t))))
          :error (cl-function
                  (lambda (&key response error-thrown &allow-other-keys)
                    (setq status (and response (request-response-status-code response))
                          failure error-thrown))))
        (unless succeeded
          (if (and (equal status 401) (= attempt 0))
              (ticktick-refresh-token)
            (signal 'ticktick-api-error
                    (list (format "%s %s failed: %s" method endpoint
                                  (or failure "unsuccessful response"))
                          status))))))
    response-data))

;;; Org conversion helpers -----------------------------------------------------

(defun ticktick--task-to-heading (task)
  "Convert TASK plist to an org heading string."
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
            (when content (string-trim content))))
     "\n")))

(defun ticktick--heading-to-task ()
  "Convert org heading at point to a TickTick task plist."
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
              (string-trim (buffer-substring-no-properties (point) (point-max)))))))
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

(defun ticktick--sync-project (project &optional project-data)
  "Sync PROJECT using fetched PROJECT-DATA, fetching it if omitted."
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
    (let ((tasks (plist-get (or project-data (ticktick--fetch-project-data project))
                            :tasks)))
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
  "Fetch remote changes, preserving local edits and recording conflicts."
  (interactive)
  (ticktick--run-sync 'pull))

(defun ticktick-push-from-org ()
  "Push local changes after checking remote versions for conflicts."
  (interactive)
  (ticktick--run-sync 'push))

(defun ticktick-sync ()
  "Reconcile local and remote tasks against their last successful baseline."
  (interactive)
  (ticktick--run-sync))

(defun ticktick--autosync ()
  "Autosync if enabled."
  (when ticktick-autosync
    (when (ticktick--sync-files-present-p)
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
  (when (ticktick--sync-files-present-p)
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
  "Delete the task at point through the guarded reconciliation executor.
Archive the local copy when configured; respect the sync-only policy."
  (interactive)
  (unless (and (derived-mode-p 'org-mode) buffer-file-name
               (member (ticktick--canonical-sync-file buffer-file-name) (ticktick--sync-files)))
    (user-error "Use this command in a TickTick sync file"))
  (when (eq ticktick-delete-behavior 'sync-only)
    (user-error "Deletion is disabled by ticktick-delete-behavior"))
  (when ticktick--sync-in-progress (user-error "TickTick sync already running"))
  (let ((ticktick--sync-in-progress t)
        (id (org-entry-get nil "TICKTICK_ID")))
    (unless id (user-error "No TickTick task at point"))
    (ticktick--ensure-state-initialized)
    (let* ((local (ticktick--local-record id))
           (remote (ticktick--read-remote-task
                    id (plist-get (plist-get local :snapshot) :project-id)))
           (operation (list :id id :key id :local (plist-get local :snapshot)
                            :remote (plist-get remote :snapshot)
                            :base (ticktick--baseline id) :local-record local
                            :remote-record remote :target nil
                            :action (if remote 'delete-remote 'delete-local))))
      (when (or (eq ticktick-delete-behavior 'delete)
                (y-or-n-p "Delete this task from Org and TickTick? "))
        (ticktick--execute-operation operation)
        (ticktick--remove-conflict id)
        (message "TickTick: task deleted")))))

;;;###autoload
(defun ticktick-retry-failed-deletions ()
  "Recheck failed deletions through reconciliation and open their review.
Never replay an old deletion without comparing current task versions."
  (interactive)
  (ticktick-sync)
  (ticktick-review-conflicts))

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

(require 'ticktick-reconcile)

(provide 'ticktick)
;;; ticktick.el ends here
