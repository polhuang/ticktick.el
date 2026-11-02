;;; ticktick-reconcile.el --- Three-way task reconciliation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Paul Huang
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Normalized task snapshots and reconciliation for ticktick.el.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'subr-x)

(defconst ticktick--snapshot-fields
  '(:title :content :status :priority :deadline :tags :project-id)
  "Fields owned by synchronization; IDs and API metadata are kept separately.")

(defun ticktick--normalize-deadline (due all-day time-zone)
  "Normalize DUE using ALL-DAY and TIME-ZONE without dropping time information."
  (when (and due (not (string-empty-p due)))
    (list :value (if all-day (substring due 0 10)
                   (format-time-string "%FT%TZ" (date-to-time due) t))
          :all-day (and all-day t) :time-zone time-zone)))

(defun ticktick--snapshot-from-api (task &optional project-id)
  "Normalize API TASK, using PROJECT-ID if the task omits it."
  (unless (and (listp task) (stringp (plist-get task :title))
               (stringp (or (plist-get task :projectId) project-id)))
    (error "TickTick: malformed task response"))
  (list :title (plist-get task :title)
        :content (string-trim (or (plist-get task :content) ""))
        :status (or (plist-get task :status) 0)
        :priority (or (plist-get task :priority) 0)
        :deadline (ticktick--normalize-deadline
                   (plist-get task :dueDate) (eq (plist-get task :isAllDay) t)
                   (plist-get task :timeZone))
        :tags (sort (delete-dups (copy-sequence (plist-get task :tags))) #'string<)
        :project-id (or (plist-get task :projectId) project-id)))

(defun ticktick--snapshot-from-org ()
  "Normalize the Org task at point, preserving deadline time and zone."
  (let* ((task (ticktick--heading-to-task))
         (element (org-element-at-point))
         (deadline (org-element-property :deadline element))
         (all-day (and deadline (not (org-element-property :hour-start deadline))))
         (due (and deadline
                   (format-time-string
                    (if all-day "%F" "%FT%TZ")
                    (org-timestamp-to-time deadline) (not all-day)))))
    (list :title (cdr (assoc "title" task))
          :content (cdr (assoc "content" task))
          :status (cdr (assoc "status" task))
          :priority (cdr (assoc "priority" task))
          :deadline (and due (list :value due :all-day all-day
                                   :time-zone (org-entry-get nil "TICKTICK_TIME_ZONE")))
          :tags (sort (delete-dups (append (cdr (assoc "tags" task)) nil)) #'string<)
          :project-id (or (org-entry-get nil "TICKTICK_PROJECT_ID" t)
                          (error "Task has no TickTick project")))))

(defun ticktick--snapshot-to-payload (snapshot &optional id)
  "Convert SNAPSHOT to an API payload, optionally including ID."
  (let* ((deadline (plist-get snapshot :deadline))
         (date (plist-get deadline :value)))
    (append (when id `(("id" . ,id)))
            `(("title" . ,(plist-get snapshot :title))
              ("content" . ,(plist-get snapshot :content))
              ("priority" . ,(plist-get snapshot :priority))
              ("projectId" . ,(plist-get snapshot :project-id))
              ("tags" . ,(vconcat (plist-get snapshot :tags)))
              ("dueDate" . ,(if (and date (plist-get deadline :all-day))
                                  (concat date "T00:00:00+0000") date))
              ("isAllDay" . ,(if (plist-get deadline :all-day) t :false)))
            (when (plist-get deadline :time-zone)
              `(("timeZone" . ,(plist-get deadline :time-zone)))))))

(defun ticktick--baseline (id)
  "Return the last reconciled snapshot for task ID."
  (cdr (assoc id (plist-get ticktick--sync-state :baselines))))

(defun ticktick--set-baseline (id snapshot)
  "Store SNAPSHOT as task ID's baseline, or remove it if nil."
  (let ((baselines (assoc-delete-all
                    id (copy-tree (plist-get ticktick--sync-state :baselines)))))
    (when snapshot (push (cons id (copy-tree snapshot)) baselines))
    (setq ticktick--sync-state
          (plist-put ticktick--sync-state :baselines baselines))))

(defun ticktick--collect-local-records ()
  "Read local task snapshots without modifying the sync file."
  (let (records seen)
    (with-current-buffer (find-file-noselect ticktick-sync-file)
      (org-with-wide-buffer
       (org-map-entries
        (lambda ()
          (when (and (= (org-current-level) 2)
                     (not (org-entry-get nil "ARCHIVED_AT")))
            (let* ((id (org-entry-get nil "TICKTICK_ID"))
                   (key (or id (org-entry-get nil "TICKTICK_LOCAL_ID")
                            (format "local:%d" (point)))))
              (when (member key seen) (error "Duplicate TickTick task ID: %s" key))
              (push key seen)
              (push (list :id id :key key :position (point)
                          :snapshot (ticktick--snapshot-from-org)) records))))
        nil nil)))
    (nreverse records)))

(defun ticktick--read-remote-task (id project-id)
  "Fetch task ID in PROJECT-ID; return nil only for a documented 404."
  (condition-case err
      (let ((task (ticktick-request
                   "GET" (format "/open/v1/project/%s/task/%s" project-id id))))
        (unless (equal (plist-get task :id) id)
          (error "TickTick: invalid response for task %s" id))
        (list :id id :key id :snapshot (ticktick--snapshot-from-api task project-id)
              :raw task))
    (ticktick-api-error
     (if (equal (nth 2 err) 404) nil (signal (car err) (cdr err))))))

(defun ticktick--collect-remote-records (local-records)
  "Fetch a complete remote snapshot, verifying known IDs from LOCAL-RECORDS.
A missing project is represented as unknown, never as confirmed deletion."
  (let* ((projects (cons '(:id "inbox" :name "Inbox")
                         (ticktick-request "GET" "/open/v1/project")))
         (known (delete-dups
                 (append (mapcar (lambda (r) (plist-get r :id)) local-records)
                         (mapcar #'car (plist-get ticktick--sync-state :baselines))
                         (plist-get ticktick--sync-state :api-task-ids)
                         (mapcar (lambda (op) (or (plist-get op :created-id)
                                                   (plist-get op :id)))
                                 (plist-get ticktick--sync-state :pending-operations)))))
         records project-ids)
    (dolist (project projects)
      (let* ((project-id (plist-get project :id))
             (data (ticktick--fetch-project-data project)))
        (unless (and (stringp project-id) (stringp (plist-get project :name)))
          (error "TickTick: malformed project"))
        (push project-id project-ids)
        (dolist (task (plist-get data :tasks))
          (let ((id (plist-get task :id)))
            (unless (and (stringp id) (not (string-empty-p id)))
              (error "TickTick: missing task ID"))
            (when (cl-find id records :key (lambda (r) (plist-get r :id)) :test #'equal)
              (error "TickTick: duplicate remote task ID %s" id))
            (push (list :id id :key id :raw task :project-name (plist-get project :name)
                        :snapshot (ticktick--snapshot-from-api task project-id)) records)))))
    (dolist (id (delq nil known))
      (unless (cl-find id records :key (lambda (r) (plist-get r :id)) :test #'equal)
        (let* ((local (cl-find id local-records :key (lambda (r) (plist-get r :id)) :test #'equal))
               (project-id (or (plist-get (ticktick--baseline id) :project-id)
                               (plist-get (plist-get local :snapshot) :project-id)
                               (ticktick--get-cached-project-id id)
                               (cl-loop for op in (plist-get ticktick--sync-state :pending-operations)
                                        when (equal id (or (plist-get op :created-id)
                                                           (plist-get op :id)))
                                        return (plist-get (plist-get op :target) :project-id))))
               (record (if (member project-id project-ids)
                           (ticktick--read-remote-task id project-id)
                         (list :id id :key id :unknown t))))
          (when record (push record records)))))
    (nreverse records)))

(defun ticktick--plan-task (local remote base)
  "Plan one task using LOCAL and REMOTE records and BASE snapshot.
This first stage deliberately holds all differing concurrent edits."
  (let* ((ours (plist-get local :snapshot))
         (theirs (plist-get remote :snapshot))
         (action (cond
                  ((plist-get remote :unknown) 'conflict)
                  ((equal ours theirs) 'agree)
                  ((and local (not (plist-get local :id))) 'create)
                  ((not base) (if (and remote (not local)
                                             (not (member (plist-get remote :id)
                                                          (plist-get ticktick--sync-state :org-task-ids))))
                                        'pull 'conflict))
                  ((or (not ours) (not theirs)) 'conflict)
                  ((equal ours base) 'pull)
                  ((equal theirs base) 'push)
                  (t 'conflict))))
    (list :id (or (plist-get local :id) (plist-get remote :id))
          :key (or (plist-get local :key) (plist-get remote :key))
          :action action :base base :local ours :remote theirs
          :target (pcase action ('pull theirs) ((or 'push 'create 'agree) ours))
          :local-record local :remote-record remote)))

(defun ticktick--build-plan (local-records remote-records)
  "Return a read-only plan for LOCAL-RECORDS and REMOTE-RECORDS."
  (let ((keys (delete-dups
               (append (mapcar (lambda (r) (plist-get r :key)) local-records)
                       (mapcar (lambda (r) (plist-get r :key)) remote-records)
                       (mapcar #'car (plist-get ticktick--sync-state :baselines)))))
        plan)
    (dolist (key keys)
      (push (ticktick--plan-task
             (cl-find key local-records :key (lambda (r) (plist-get r :key)) :test #'equal)
             (cl-find key remote-records :key (lambda (r) (plist-get r :key)) :test #'equal)
             (ticktick--baseline key)) plan)
      ;; Both copies may have disappeared; preserve the identity in the plan.
      (unless (plist-get (car plan) :local-record)
        (setf (plist-get (car plan) :id) (or (plist-get (car plan) :id) key)))
      (setf (plist-get (car plan) :key) key))
    (nreverse plan)))

;;;###autoload
(defun ticktick-preview-sync ()
  "Fetch snapshots and display a reconciliation plan without writing tasks."
  (interactive)
  (ticktick--ensure-state-initialized)
  (let* ((local (ticktick--collect-local-records))
         (remote (ticktick--collect-remote-records local)))
    (with-output-to-temp-buffer "*TickTick Sync Plan*"
      (dolist (operation (ticktick--build-plan local remote))
        (princ (format "%s  %s\n" (plist-get operation :action)
                       (or (plist-get (plist-get operation :local) :title)
                           (plist-get (plist-get operation :remote) :title)
                           (plist-get operation :key))))))))

(defvar ticktick--sync-in-progress nil
  "Non-nil while reconciliation is running in this Emacs.")

(defun ticktick--local-record (key)
  "Return the current local task identified by KEY."
  (cl-find key (ticktick--collect-local-records)
           :key (lambda (record) (plist-get record :key)) :test #'equal))

(defun ticktick--project-position (project-id name)
  "Find PROJECT-ID's heading, creating it using NAME if needed."
  (or (save-excursion
        (goto-char (point-min))
        (catch 'found
          (org-map-entries
           (lambda ()
             (when (and (= (org-current-level) 1)
                        (equal (org-entry-get nil "TICKTICK_PROJECT_ID") project-id))
               (throw 'found (point)))) nil nil)
          nil))
      (ticktick--create-project-heading (or name project-id) project-id)))

(defun ticktick--write-local-snapshot (key id snapshot &optional project-name)
  "Save SNAPSHOT locally, finding KEY and assigning ID.
Preserve unrelated properties on existing entries.  Use PROJECT-NAME for imports."
  (let ((record (ticktick--local-record key)))
    (with-current-buffer (find-file-noselect ticktick-sync-file)
      (org-with-wide-buffer
       (let* ((project-id (plist-get snapshot :project-id))
              (position (plist-get record :position))
              (org-inhibit-logging t)
              (org-log-done nil)
              (org-log-repeat nil))
         (when position
           (goto-char position)
           (unless (equal (org-entry-get nil "TICKTICK_PROJECT_ID" t) project-id)
             (let* ((start (point))
                    (end (save-excursion (org-end-of-subtree t t)))
                    (text (buffer-substring-no-properties start end)))
               (delete-region start end)
               (goto-char (ticktick--project-position project-id project-name))
               (org-end-of-subtree t t)
               (unless (bolp) (insert "\n"))
               (setq position (point))
               (insert text)
               (unless (bolp) (insert "\n")))))
         (unless position
           (goto-char (ticktick--project-position project-id project-name))
           (org-end-of-subtree t t)
           (unless (bolp) (insert "\n"))
           (setq position (point))
           (insert "** TODO Task\n"))
         (goto-char position)
         (org-edit-headline (plist-get snapshot :title))
         (org-todo (if (= (plist-get snapshot :status) 2) "DONE" "TODO"))
         (let ((priority (pcase (plist-get snapshot :priority)
                           (5 ?A) (3 ?B) (1 ?C))))
           (cond (priority (org-priority priority))
                 ((org-element-property :priority (org-element-at-point))
                  (org-priority ?\s))))
         (org-set-tags (plist-get snapshot :tags))
         (let* ((deadline (plist-get snapshot :deadline))
                (value (plist-get deadline :value)))
           (if value
               (org-deadline nil
                             (if (plist-get deadline :all-day) value
                               (format-time-string "%F %a %H:%M" (date-to-time value))))
             (when (org-entry-get nil "DEADLINE") (org-deadline '(4))))
           (if (plist-get deadline :time-zone)
               (org-entry-put nil "TICKTICK_TIME_ZONE" (plist-get deadline :time-zone))
             (org-entry-delete nil "TICKTICK_TIME_ZONE")))
         (when id (org-entry-put nil "TICKTICK_ID" id))
         (save-excursion
           (org-end-of-meta-data t)
           (let ((start (point))
                 (end (org-entry-end-position)))
             (delete-region start end)
             (insert (plist-get snapshot :content) "\n")))
         (goto-char position)
         (ticktick--update-sync-meta)
         (save-buffer))))))

(defun ticktick--journal-put (operation)
  "Persist OPERATION before performing its next mutation."
  (let* ((key (plist-get operation :key))
         (others (cl-remove key (plist-get ticktick--sync-state :pending-operations)
                            :key (lambda (op) (plist-get op :key)) :test #'equal)))
    (setq ticktick--sync-state
          (plist-put ticktick--sync-state :pending-operations
                     (cons (copy-tree operation) others)))
    (ticktick--save-state)))

(defun ticktick--finish-operation (operation id target)
  "Record successful OPERATION with ID and reconciled TARGET."
  (ticktick--set-baseline id target)
  (setq ticktick--sync-state
        (plist-put ticktick--sync-state :pending-operations
                   (cl-remove (plist-get operation :key)
                              (plist-get ticktick--sync-state :pending-operations)
                              :key (lambda (op) (plist-get op :key)) :test #'equal)))
  (ticktick--save-state))

(defun ticktick--check-local-version (operation)
  "Refuse OPERATION if its local source changed since planning."
  (unless (equal (plist-get operation :local)
                 (plist-get (ticktick--local-record (plist-get operation :key)) :snapshot))
    (error "TickTick: local task changed since planning")))

(defun ticktick--check-remote-version (operation)
  "Refetch and verify OPERATION's remote source before mutation."
  (let* ((snapshot (plist-get operation :remote))
         (id (plist-get operation :id))
         (current (and id snapshot
                       (ticktick--read-remote-task id (plist-get snapshot :project-id)))))
    (unless (equal snapshot (plist-get current :snapshot))
      (error "TickTick: remote task changed since planning"))
    current))

(defun ticktick--push-snapshot (id target remote)
  "Write TARGET for ID, preserving remote fields outside our ownership.
REMOTE is the freshly verified remote record.  Return the verified record."
  (let* ((project-id (plist-get target :project-id))
         (previous (plist-get remote :snapshot))
         (old-project (plist-get previous :project-id))
         (status (plist-get target :status)))
    (when (and (= (or (plist-get previous :status) 0) 2) (/= status 2))
      (error "TickTick: reopening completed tasks is not supported by this client"))
    (when (and old-project (not (equal project-id old-project)))
      (ticktick-request "POST" "/open/v1/task/move"
                       (vector `(("fromProjectId" . ,old-project)
                                 ("toProjectId" . ,project-id) ("taskId" . ,id)))))
    (let* ((owned (ticktick--snapshot-to-payload target id))
           (raw (plist-get remote :raw))
           ;; Preserve reminders, recurrence, checklist items and start date.
           (extras (cl-loop for field in '(:desc :startDate :reminders :repeatFlag :items :sortOrder)
                            when (plist-member raw field)
                            collect (cons (substring (symbol-name field) 1)
                                          (if (memq field '(:items :reminders))
                                              (vconcat (plist-get raw field))
                                            (plist-get raw field))))))
      (ticktick-request "POST" (format "/open/v1/task/%s" id) (append owned extras)))
    (when (and (= status 2) (/= (or (plist-get previous :status) 0) 2))
      (ticktick-request "POST" (format "/open/v1/project/%s/task/%s/complete" project-id id)))
    (let ((result (ticktick--read-remote-task id project-id)))
      (unless (equal target (plist-get result :snapshot))
        (error "TickTick: remote update did not match the intended task"))
      result)))

(cl-defun ticktick--execute-operation (operation)
  "Execute one nonconflicting OPERATION with durable intent tracking."
  (ticktick--check-local-version operation)
  (when (eq (plist-get operation :action) 'agree)
    (cl-return-from ticktick--execute-operation
      (ticktick--finish-operation operation (plist-get operation :id)
                                  (plist-get operation :target))))
  (let* ((action (plist-get operation :action))
         (key (plist-get operation :key))
         (id (plist-get operation :id))
         (target (plist-get operation :target))
         (remote (unless (eq action 'create) (ticktick--check-remote-version operation))))
    (when (eq action 'create)
      ;; Give new headings an identity that survives edits and restarts.
      (require 'org-id)
      (let ((record (ticktick--local-record key)))
        (with-current-buffer (find-file-noselect ticktick-sync-file)
          (goto-char (plist-get record :position))
          (setq key (or (org-entry-get nil "TICKTICK_LOCAL_ID") (org-id-new)))
          (org-entry-put nil "TICKTICK_LOCAL_ID" key)
          (save-buffer)))
      (setq operation (plist-put operation :key key)))
    (setq operation (plist-put operation :phase 'prepared))
    (ticktick--journal-put operation)
    (pcase action
      ('push (setq remote (ticktick--push-snapshot id target remote)))
      ('create
       (let ((response (ticktick-request "POST" "/open/v1/task"
                                         (ticktick--snapshot-to-payload target))))
         (setq id (plist-get response :id))
         (unless (and (stringp id) (not (string-empty-p id)))
           (error "TickTick: creation outcome unknown; review pending operation"))
         ;; Save the returned ID before verification or any local writes.
         (setq operation (plist-put operation :created-id id))
         (ticktick--journal-put operation)
         (setq remote (ticktick--read-remote-task id (plist-get target :project-id)))
         (when (= (plist-get target :status) 2)
           (setq remote (ticktick--push-snapshot id target remote)))
         (unless (equal target (plist-get remote :snapshot))
           (error "TickTick: created task differs from intended task")))))
    (setq operation (plist-put operation :phase 'remote-applied))
    (ticktick--journal-put operation)
    ;; A network call may have allowed an Org edit while Emacs was waiting.
    (ticktick--check-local-version operation)
    (when target
      (ticktick--write-local-snapshot
       key id target (plist-get (plist-get operation :remote-record) :project-name)))
    (unless (equal target (plist-get (ticktick--local-record (or id key)) :snapshot))
      (error "TickTick: local save did not preserve intended task"))
    (ticktick--finish-operation operation id target)))

(defun ticktick--recover-pending (local remote)
  "Reconcile interrupted operations against current LOCAL and REMOTE snapshots.
Never automatically resubmit a creation whose returned ID was not recorded."
  (dolist (operation (copy-tree (plist-get ticktick--sync-state :pending-operations)))
    (let* ((key (plist-get operation :key))
           (id (or (plist-get operation :created-id) (plist-get operation :id)))
           (target (plist-get operation :target))
           (ours (cl-find (or id key) local :key (lambda (r) (plist-get r :key)) :test #'equal))
           (ours (or ours (cl-find key local :key (lambda (r) (plist-get r :key)) :test #'equal)))
           (theirs (cl-find id remote :key (lambda (r) (plist-get r :id)) :test #'equal)))
      (when (and id (equal target (plist-get theirs :snapshot))
                 (or (equal (plist-get ours :snapshot) target)
                     (equal (plist-get ours :snapshot) (plist-get operation :local))))
        (ticktick--write-local-snapshot (plist-get ours :key) id target)
        (ticktick--finish-operation operation id target)))))

(defun ticktick--run-sync (&optional direction)
  "Reconcile tasks, optionally limiting writes to DIRECTION (pull or push)."
  (when ticktick--sync-in-progress (user-error "TickTick sync already running"))
  (let ((ticktick--sync-in-progress t))
    (ticktick--ensure-state-initialized)
    (let* ((local (ticktick--collect-local-records))
           (remote (ticktick--collect-remote-records local)))
      (ticktick--recover-pending local remote)
      (setq local (ticktick--collect-local-records))
      (let ((plan (ticktick--build-plan local remote))
            conflicts)
        (dolist (operation plan)
          (let* ((key (plist-get operation :key))
                 (action (plist-get operation :action))
                 (pending (cl-find key (plist-get ticktick--sync-state :pending-operations)
                                   :key (lambda (op) (plist-get op :key)) :test #'equal)))
            (cond
             ((or pending (eq action 'conflict))
              (push (or pending operation) conflicts))
             ((or (and (eq direction 'pull) (memq action '(push create)))
                  (and (eq direction 'push) (eq action 'pull))) nil)
             (t
              (condition-case err
                  (ticktick--execute-operation operation)
                (error
                 (setq operation (plist-put operation :error (error-message-string err)))
                 (push operation conflicts)))))))
        (setq ticktick--sync-state (plist-put ticktick--sync-state :conflicts (nreverse conflicts)))
        (setq ticktick--sync-state (plist-put ticktick--sync-state :last-sync-time (format-time-string "%FT%T%z")))
        (ticktick--save-state)
        (message "TickTick: sync finished; %d task(s) need review" (length conflicts))))))

(provide 'ticktick-reconcile)
;;; ticktick-reconcile.el ends here
