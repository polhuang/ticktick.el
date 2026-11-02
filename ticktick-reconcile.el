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

;; Shared configuration and helpers are defined by ticktick.el before loading us.
(defvar ticktick--sync-state)
(defvar ticktick--sync-in-progress nil
  "Non-nil while reconciliation is running in this Emacs.")
(defvar ticktick-sync-file)
(defvar ticktick-project-files)
(defvar ticktick-dir)
(defvar ticktick-delete-behavior)
(defvar ticktick-confirm-deletions)
(defvar ticktick-archive-location)
(defvar ticktick-archive-file)
(declare-function ticktick--heading-to-task "ticktick")
(declare-function ticktick-request "ticktick" (method endpoint &optional data))
(declare-function ticktick--fetch-project-data "ticktick" (project))
(declare-function ticktick--get-cached-project-id "ticktick" (id))
(declare-function ticktick--ensure-state-initialized "ticktick")
(declare-function ticktick--create-project-heading "ticktick" (name id))
(declare-function ticktick--update-sync-meta "ticktick")
(declare-function ticktick--save-state "ticktick")
(declare-function ticktick--collect-org-task-ids "ticktick")
(declare-function ticktick--collect-task-project-map "ticktick")
(declare-function ticktick--delete-task-from-api "ticktick" (id &optional project-id))
(declare-function ticktick--task-to-heading "ticktick" (task))
(declare-function ticktick-sync "ticktick")
(declare-function custom-file "cus-edit" (&optional no-error))

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
                    (org-timestamp-to-time deadline) (not all-day))))
         (original (org-entry-get nil "TICKTICK_DUE_VALUE")))
    (when (and due original (not all-day)
               (equal (substring due 0 16) (substring original 0 (min 16 (length original)))))
      (setq due original))
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

(defun ticktick--canonical-sync-file (file)
  "Return a canonical absolute FILE, resolving relative paths under ticktick-dir."
  (file-truename (expand-file-name file ticktick-dir)))

(defun ticktick--project-file (project-id)
  "Return the Org destination for PROJECT-ID."
  (ticktick--canonical-sync-file
   (or (cdr (assoc project-id ticktick-project-files)) ticktick-sync-file)))

(defun ticktick--sync-files ()
  "Return configured and remembered files, deduplicating aliases.
Remember old destinations so changing a mapping does not look like deletion."
  (delete-dups
   (mapcar #'ticktick--canonical-sync-file
           (delq nil
                 (append (list ticktick-sync-file) (mapcar #'cdr ticktick-project-files)
                         (plist-get ticktick--sync-state :sync-files)
                         (cl-loop for move in (plist-get ticktick--sync-state :file-moves)
                                  append (list (plist-get move :source) (plist-get move :destination)))
                         (mapcar (lambda (op) (plist-get (plist-get op :local-record) :file))
                                 (plist-get ticktick--sync-state :pending-operations)))))))

(defun ticktick--sync-files-present-p ()
  "Return non-nil if any configured or remembered sync file is present."
  (cl-some (lambda (file) (or (file-exists-p file) (find-buffer-visiting file)))
           (ticktick--sync-files)))

(defun ticktick--remember-sync-files ()
  "Persist known files before routing tasks to their destinations."
  (setq ticktick--sync-state
        (plist-put ticktick--sync-state :sync-files (ticktick--sync-files)))
  (ticktick--save-state))

(defun ticktick--org-buffer (file)
  "Visit FILE, reusing a buffer already visiting the same canonical file."
  (or (find-buffer-visiting file) (find-file-noselect file)))

(defun ticktick--writable-org-buffer (file)
  "Visit FILE for writing, creating its parent directories when needed."
  (make-directory (file-name-directory file) t)
  (ticktick--org-buffer file))

(defun ticktick--records-in-file (file)
  "Read active task records in FILE, ignoring unrelated Org headings."
  (let (records)
    (when (or (file-exists-p file) (find-buffer-visiting file))
      (with-current-buffer (ticktick--org-buffer file)
        (org-with-wide-buffer
         (org-map-entries
          (lambda ()
            (when (and (= (org-current-level) 2)
                       (not (org-entry-get nil "ARCHIVED_AT")))
              (let* ((id (org-entry-get nil "TICKTICK_ID"))
                     (local-id (org-entry-get nil "TICKTICK_LOCAL_ID"))
                     (project-id (org-entry-get nil "TICKTICK_PROJECT_ID" t)))
                (when (and (or id local-id) (not project-id))
                  (error "TickTick task %s has no project in %s" (or id local-id) file))
                (when project-id
                  (push (list :id id :key (or id local-id (format "local:%s:%d" file (point)))
                              :file file :position (point)
                              :snapshot (ticktick--snapshot-from-org)) records)))))
          nil nil))))
    (nreverse records)))

(defun ticktick--collect-local-records ()
  "Read task snapshots across all sync files without modifying them."
  (let (records seen)
    (dolist (file (ticktick--sync-files))
      (dolist (record (ticktick--records-in-file file))
        (let ((key (plist-get record :key)))
          (when (member key seen) (error "Duplicate TickTick task ID: %s" key))
          (push key seen)
          (push record records))))
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

(defun ticktick--list-projects ()
  "Fetch project IDs and display names directly from TickTick, including Inbox."
  (let ((projects (cons '(:id "inbox" :name "Inbox")
                        (cl-remove "inbox" (ticktick-request "GET" "/open/v1/project")
                                   :key (lambda (project) (plist-get project :id)) :test #'equal)))
        seen)
    (dolist (project projects)
      (let ((id (plist-get project :id)) (name (plist-get project :name)))
        (unless (and (stringp id) (not (string-empty-p id))
                     (stringp name) (not (string-empty-p name))
                     (not (member id seen)))
          (error "TickTick: invalid or duplicate project"))
        (push id seen)))
    projects))

(defun ticktick--configure-project-file (session-only)
  "Choose and initialize a project destination, optionally SESSION-ONLY."
  (let* ((projects (ticktick--list-projects))
         (choices (mapcar
                   (lambda (project)
                     (let ((name (plist-get project :name)))
                       (cons (if (> (cl-count name projects :key (lambda (p) (plist-get p :name))
                                              :test #'equal) 1)
                                 (format "%s [%s]" name (plist-get project :id)) name)
                             project)))
                   projects))
         (project (cdr (assoc (completing-read "TickTick project: " choices nil t) choices)))
         (id (plist-get project :id))
         (name (plist-get project :name)))
    (unless id (user-error "Choose a TickTick project"))
    (let* ((slug (string-trim (replace-regexp-in-string "[^[:alnum:]_-]+" "-" (downcase name)) "-+" "-+"))
           (suggested (or (cdr (assoc id ticktick-project-files))
                          (expand-file-name (concat (if (string-empty-p slug) "project" slug) ".org")
                                            (file-name-directory
                                             (ticktick--canonical-sync-file ticktick-sync-file)))))
           (default (ticktick--canonical-sync-file suggested))
           (file (ticktick--canonical-sync-file
                  (expand-file-name
                   (read-file-name (format "Org file for %s: " name)
                                   (file-name-directory default) default nil
                                   (file-name-nondirectory default))
                   (file-name-directory default))))
           (previous (copy-tree ticktick-project-files)))
      (when (file-directory-p file) (user-error "Choose an Org file, not a directory"))
      (unless session-only
        (require 'cus-edit)
        (unless (custom-file t)
          (user-error "Cannot save preferences here; use C-u M-x ticktick-set-project-file for this session")))
      (ticktick--ensure-state-initialized)
      ;; Preserve previous destinations even when remapping before the first sync.
      (ticktick--remember-sync-files)
      (with-current-buffer (ticktick--writable-org-buffer file)
        (org-with-wide-buffer
         (ticktick--project-position id name)
         (save-buffer)))
      (let ((mappings (cons (cons id file) (assoc-delete-all id (copy-tree previous)))))
        (if session-only
            (setq ticktick-project-files mappings)
          (condition-case err
              (progn
                (customize-save-variable 'ticktick-project-files mappings)
                (setq ticktick-project-files mappings))
            (error
             (setq ticktick-project-files previous)
             (signal (car err) (cdr err))))))
      (ticktick--remember-sync-files)
      (message "TickTick: %s uses %s%s. Run ticktick-sync to import tasks."
               name file (if session-only " (this session)" " (saved)"))
      (cons id file))))

(defun ticktick--collect-remote-records (local-records)
  "Fetch a complete remote snapshot, verifying known IDs from LOCAL-RECORDS.
A missing project is represented as unknown, never as confirmed deletion."
  (let* ((projects (ticktick--list-projects))
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

(defun ticktick--merge-snapshots (base local remote)
  "Merge BASE, LOCAL and REMOTE field by field.
Return a plist with :snapshot and a list of :conflicting-fields.
Descriptions, deadlines and tag lists are each treated as a whole field."
  (let (snapshot conflicts)
    (dolist (field ticktick--snapshot-fields)
      (let ((before (plist-get base field))
            (ours (plist-get local field))
            (theirs (plist-get remote field)))
        (setq snapshot
              (plist-put snapshot field
                         (cond ((equal ours theirs) ours)
                               ((equal ours before) theirs)
                               ((equal theirs before) ours)
                               (t (push field conflicts) ours))))))
    (list :snapshot snapshot :conflicting-fields (nreverse conflicts))))

(defun ticktick--plan-task (local remote base)
  "Plan one task using LOCAL and REMOTE records and BASE snapshot.
Merge independent edits, holding the entire task if any field conflicts."
  (let* ((ours (plist-get local :snapshot))
         (theirs (plist-get remote :snapshot))
         (merge (and base ours theirs (ticktick--merge-snapshots base ours theirs)))
         (action (cond
                  ((plist-get remote :unknown) 'conflict)
                  ((equal ours theirs) 'agree)
                  ((and local (not (plist-get local :id))) 'create)
                  ((not base) (if (and remote (not local)
                                             (not (member (plist-get remote :id)
                                                          (plist-get ticktick--sync-state :org-task-ids))))
                                        'pull 'conflict))
                  ((and (not ours) (equal theirs base)) 'delete-remote)
                  ((and (not theirs) (equal ours base)) 'delete-local)
                  ((or (not ours) (not theirs)) 'conflict)
                  ((equal ours base) 'pull)
                  ((equal theirs base) 'push)
                  ((not (plist-get merge :conflicting-fields)) 'merge)
                  (t 'conflict))))
    (list :id (or (plist-get local :id) (plist-get remote :id))
          :key (or (plist-get local :key) (plist-get remote :key))
          :action action :base base :local ours :remote theirs
          :conflicting-fields (plist-get merge :conflicting-fields)
          :target (pcase action ('pull theirs) ((or 'push 'create 'agree) ours)
                         ('merge (plist-get merge :snapshot)))
          :local-record local :remote-record remote)))

(defun ticktick--build-plan (local-records remote-records)
  "Return a read-only plan for LOCAL-RECORDS and REMOTE-RECORDS."
  ;; A returned creation ID is a durable identity even if local saving or
  ;; verification failed.  Pair it with its original heading, not a second import.
  (setq local-records (copy-tree local-records)
        remote-records (copy-tree remote-records))
  (dolist (pending (plist-get ticktick--sync-state :pending-operations))
    (let* ((id (plist-get pending :created-id))
           (key (plist-get pending :key))
           (local (cl-find key local-records :key (lambda (r) (plist-get r :key)) :test #'equal))
           (remote (and id (cl-find id remote-records :key (lambda (r) (plist-get r :id)) :test #'equal))))
      (when id
        (when local (setf (plist-get local :id) id))
        (when remote (setf (plist-get remote :key) key)))))
  (let ((keys (delete-dups
               (append (mapcar (lambda (r) (plist-get r :key)) local-records)
                       (mapcar (lambda (r) (plist-get r :key)) remote-records)
                       (mapcar #'car (plist-get ticktick--sync-state :baselines))
                       (mapcar (lambda (op) (plist-get op :key))
                               (plist-get ticktick--sync-state :pending-operations)))))
        plan)
    (dolist (key keys)
      (push (ticktick--plan-task
             (cl-find key local-records :key (lambda (r) (plist-get r :key)) :test #'equal)
             (cl-find key remote-records :key (lambda (r) (plist-get r :key)) :test #'equal)
             (ticktick--baseline key)) plan)
      ;; Both copies may have disappeared; preserve the identity in the plan.
      (unless (plist-get (car plan) :local-record)
        (let ((pending (cl-find key (plist-get ticktick--sync-state :pending-operations)
                                :key (lambda (op) (plist-get op :key)) :test #'equal)))
          (setf (plist-get (car plan) :id)
                (or (plist-get (car plan) :id) (plist-get pending :created-id)
                    (plist-get pending :id) (and (not pending) key)))))
      (setf (plist-get (car plan) :key) key))
    (nreverse plan)))

;;;###autoload
(defun ticktick-preview-sync ()
  "Fetch snapshots and display a reconciliation plan without writing tasks."
  (interactive)
  (when ticktick--sync-in-progress (user-error "TickTick sync already running"))
  (ticktick--ensure-state-initialized)
  (let* ((local (ticktick--collect-local-records))
         (remote (ticktick--collect-remote-records local)))
    (with-output-to-temp-buffer "*TickTick Sync Plan*"
      (dolist (operation (ticktick--build-plan local remote))
        (princ (format "%s  %s\n" (plist-get operation :action)
                       (or (plist-get (plist-get operation :local) :title)
                           (plist-get (plist-get operation :remote) :title)
                           (plist-get operation :key))))))))

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

(defun ticktick--record-in-file (file key)
  "Find KEY in FILE, rejecting duplicate identities within that file."
  (let ((records (cl-remove-if-not
                  (lambda (record) (equal (plist-get record :key) key))
                  (ticktick--records-in-file file))))
    (when (cdr records) (error "Duplicate TickTick task %s in %s" key file))
    (car records)))

(defun ticktick--record-text (record)
  "Return RECORD's full subtree, including unrelated Org properties."
  (with-current-buffer (ticktick--org-buffer (plist-get record :file))
    (org-with-wide-buffer
     (goto-char (plist-get record :position))
     (buffer-substring-no-properties (point) (save-excursion (org-end-of-subtree t t))))))

(defun ticktick--same-move-text-p (text original)
  "Compare TEXT and ORIGINAL, allowing an added final newline."
  (equal (string-trim-right text "\n") (string-trim-right original "\n")))

(defun ticktick--complete-file-move (move)
  "Finish durable local MOVE, preserving a copy until the destination is saved."
  (let* ((key (plist-get move :key))
         (source-file (plist-get move :source))
         (destination-file (plist-get move :destination))
         (source (ticktick--record-in-file source-file key))
         (destination (ticktick--record-in-file destination-file key))
         (text (plist-get move :text)))
    (when (and source (not (ticktick--same-move-text-p (ticktick--record-text source) text)))
      (error "TickTick: source changed; inspect file move from %s to %s"
             source-file destination-file))
    (unless destination
      (unless source (error "TickTick: neither copy of task %s is available" key))
      (with-current-buffer (ticktick--writable-org-buffer destination-file)
        (org-with-wide-buffer
         (goto-char (ticktick--project-position (plist-get move :project-id)
                                               (plist-get move :project-name)))
         (org-end-of-subtree t t)
         (unless (bolp) (insert "\n"))
         (insert text)
         (unless (bolp) (insert "\n"))
         (save-buffer)))
      (setq destination (ticktick--record-in-file destination-file key)))
    (unless (and destination
                 (ticktick--same-move-text-p (ticktick--record-text destination) text))
      (error "TickTick: destination changed; inspect file move from %s to %s"
             source-file destination-file))
    (with-current-buffer (ticktick--org-buffer destination-file)
      ;; Retry a destination save that previously failed after buffer insertion.
      (when (buffer-modified-p) (save-buffer)))
    (with-current-buffer (ticktick--org-buffer source-file)
      (org-with-wide-buffer
       (when source
         (goto-char (plist-get source :position))
         (delete-region (point) (save-excursion (org-end-of-subtree t t))))
       ;; A previous removal may still be unsaved in this buffer.
       (when (buffer-modified-p) (save-buffer))))
    (setq ticktick--sync-state
          (plist-put ticktick--sync-state :file-moves
                     (cl-remove key (plist-get ticktick--sync-state :file-moves)
                                :key (lambda (entry) (plist-get entry :key)) :test #'equal)))
    (ticktick--save-state)))

(defun ticktick--recover-file-moves ()
  "Finish interrupted file moves before scanning for duplicate task IDs."
  (dolist (move (copy-tree (plist-get ticktick--sync-state :file-moves)))
    (ticktick--complete-file-move move)))

(defun ticktick--relocate-record (record destination project-id project-name)
  "Move RECORD to DESTINATION under PROJECT-ID, preserving its full subtree.
Use PROJECT-NAME when a destination project heading must be created."
  (let* ((key (plist-get record :key))
         (move (list :key key :source (plist-get record :file)
                     :destination destination :text (ticktick--record-text record)
                     :project-id project-id :project-name project-name)))
    (setq ticktick--sync-state
          (plist-put ticktick--sync-state :file-moves
                     (cons move (cl-remove key (plist-get ticktick--sync-state :file-moves)
                                           :key (lambda (entry) (plist-get entry :key)) :test #'equal))))
    (ticktick--save-state)
    (ticktick--complete-file-move move)))

(defun ticktick--write-local-snapshot (key id snapshot &optional project-name)
  "Save SNAPSHOT locally, finding KEY and assigning ID.
Preserve unrelated properties on existing entries.
Use PROJECT-NAME for imports."
  (ticktick--remember-sync-files)
  (let* ((record (ticktick--local-record key))
         (destination (ticktick--project-file (plist-get snapshot :project-id))))
    (when (and record (not (equal (plist-get record :file) destination)))
      (ticktick--relocate-record record destination (plist-get snapshot :project-id) project-name)
      (setq record (ticktick--local-record key)))
    (with-current-buffer (ticktick--writable-org-buffer destination)
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
           (if value
               (org-entry-put nil "TICKTICK_DUE_VALUE" value)
             (org-entry-delete nil "TICKTICK_DUE_VALUE"))
           (if (plist-get deadline :time-zone)
               (org-entry-put nil "TICKTICK_TIME_ZONE" (plist-get deadline :time-zone))
             (org-entry-delete nil "TICKTICK_TIME_ZONE")))
         (when id (org-entry-put nil "TICKTICK_ID" id))
         (save-excursion
           (org-end-of-meta-data t)
           (let ((start (point))
                 (end (save-excursion (org-end-of-subtree t t))))
             (delete-region start end)
             (insert (plist-get snapshot :content) "\n")))
         (goto-char position)
         (ticktick--update-sync-meta)
         (save-buffer))))))

(defun ticktick--remove-local-task (id)
  "Remove task ID locally, archiving it first when configured.
Archive writes precede source removal and retries reuse an existing archive."
  (let ((record (ticktick--local-record id)))
    (when record
      (with-current-buffer (ticktick--org-buffer (plist-get record :file))
        (org-with-wide-buffer
         (goto-char (plist-get record :position))
         (let* ((start (copy-marker (point)))
                (end (copy-marker (save-excursion (org-end-of-subtree t t))))
                (text (buffer-substring-no-properties start end)))
           (unwind-protect
               (progn
                 (when (eq ticktick-delete-behavior 'archive)
                   (with-current-buffer
                       (ticktick--writable-org-buffer
                        (if (eq ticktick-archive-location 'separate-file)
                            ticktick-archive-file (plist-get record :file)))
                     (org-with-wide-buffer
                      (goto-char (point-min))
                      (unless (catch 'archived
                                (org-map-entries
                                 (lambda ()
                                   (when (and (equal (org-entry-get nil "TICKTICK_ID") id)
                                              (org-entry-get nil "ARCHIVED_AT"))
                                     (throw 'archived t))) nil nil)
                                nil)
                        (goto-char (point-min))
                        (unless (re-search-forward "^\\* Archived Tasks$" nil t)
                          (goto-char (point-max))
                          (unless (bolp) (insert "\n"))
                          (insert "* Archived Tasks\n")
                          (forward-line -1))
                        (org-back-to-heading t)
                        (org-end-of-subtree t t)
                        (unless (bolp) (insert "\n"))
                        (let ((position (point)))
                          (insert text)
                          (unless (bolp) (insert "\n"))
                          (goto-char position)
                          (org-entry-put nil "ARCHIVED_AT" (format-time-string "%FT%T%z"))
                          (org-entry-put nil "ARCHIVED_REASON" "Deleted during TickTick sync")))
                      (save-buffer))))
                 (delete-region start end)
                 (save-buffer))
             (set-marker start nil)
             (set-marker end nil))))))))

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
  (let ((previous-state (copy-tree ticktick--sync-state)))
    (condition-case err
        (progn
          (when (plist-get operation :replaces-id)
            (ticktick--set-baseline (plist-get operation :replaces-id) nil))
          (ticktick--set-baseline id target)
          (setq ticktick--sync-state
                (plist-put ticktick--sync-state :pending-operations
                           (cl-remove (plist-get operation :key)
                                      (plist-get ticktick--sync-state :pending-operations)
                                      :key (lambda (op) (plist-get op :key)) :test #'equal)))
          (setq ticktick--sync-state
                (plist-put ticktick--sync-state :failed-operations
                           (cl-remove-if
                            (lambda (op) (member (plist-get op :task-id)
                                                 (list id (plist-get operation :replaces-id))))
                            (plist-get ticktick--sync-state :failed-operations))))
          (ticktick--save-state))
      (error
       (setq ticktick--sync-state previous-state)
       (signal (car err) (cdr err))))))

(defun ticktick--check-local-version (operation)
  "Refuse OPERATION if its local source changed since planning."
  (unless (equal (plist-get operation :local)
                 (plist-get (ticktick--local-record (plist-get operation :key)) :snapshot))
    (error "TickTick: local task changed since planning")))

(defun ticktick--check-remote-version (operation)
  "Refetch and verify OPERATION's remote source before mutation."
  (let* ((snapshot (plist-get operation :remote))
         (id (plist-get operation :id))
         (project-id (plist-get (or snapshot (plist-get operation :base)
                                    (plist-get operation :local)
                                    (plist-get (plist-get operation :pending-intent) :target)) :project-id))
         (current (and id project-id (ticktick--read-remote-task id project-id))))
    (unless (equal snapshot (plist-get current :snapshot))
      (error "TickTick: remote task changed since planning"))
    current))

(defun ticktick--snapshots-equivalent-p (expected actual)
  "Compare EXPECTED and ACTUAL, accepting an API-supplied default time zone."
  (let ((copy (copy-tree expected)))
    (when (and (plist-get copy :deadline) (plist-get actual :deadline)
               (not (plist-get (plist-get copy :deadline) :time-zone)))
      (setf (plist-get (plist-get copy :deadline) :time-zone)
            (plist-get (plist-get actual :deadline) :time-zone)))
    (equal copy actual)))

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
      (unless (ticktick--snapshots-equivalent-p target (plist-get result :snapshot))
        (error "TickTick: remote update did not match the intended task"))
      result)))

(cl-defun ticktick--execute-operation (operation)
  "Execute one nonconflicting OPERATION with durable intent tracking."
  (ticktick--check-local-version operation)
  (when (and (eq (plist-get operation :action) 'agree)
             (let ((record (ticktick--local-record (plist-get operation :key))))
               (or (not record)
                   (equal (plist-get record :file)
                          (ticktick--project-file (plist-get (plist-get operation :target) :project-id))))))
    (cl-return-from ticktick--execute-operation
      (ticktick--finish-operation operation (plist-get operation :id)
                                  (plist-get operation :target))))
  (let* ((action (plist-get operation :action))
         (key (plist-get operation :key))
         (id (plist-get operation :id))
         (target (plist-get operation :target))
         (remote (unless (eq action 'create) (ticktick--check-remote-version operation))))
    (ticktick--check-local-version operation)
    (when (eq action 'create)
      ;; Give new headings an identity that survives edits and restarts.
      (require 'org-id)
      (let ((record (ticktick--local-record key)))
        (unless (plist-get operation :replaces-id)
          (with-current-buffer (ticktick--writable-org-buffer (plist-get record :file))
            (goto-char (plist-get record :position))
            (setq key (or (org-entry-get nil "TICKTICK_LOCAL_ID") (org-id-new)))
            (org-entry-put nil "TICKTICK_LOCAL_ID" key)
            (save-buffer))))
      (setq operation (plist-put operation :key key)))
    (setq operation (plist-put operation :phase 'prepared))
    (ticktick--journal-put operation)
    (pcase action
      ('delete-remote
       (unless (ticktick--delete-task-from-api id (plist-get (plist-get operation :remote) :project-id))
         (error "TickTick: deletion failed"))
       (when (ticktick--read-remote-task id (plist-get (plist-get operation :remote) :project-id))
         (error "TickTick: deleted task is still present"))
       (ticktick--check-local-version operation)
       (when (plist-get operation :local) (ticktick--remove-local-task id)))
      ('delete-local
       (ticktick--check-local-version operation)
       (ticktick--remove-local-task id))
      ((or 'push 'merge) (setq remote (ticktick--push-snapshot id target remote)))
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
         (unless (ticktick--snapshots-equivalent-p target (plist-get remote :snapshot))
           (error "TickTick: created task differs from intended task")))))
    (when (memq action '(push merge create))
      (setq target (plist-get remote :snapshot))
      (setq operation (plist-put operation :target target)))
    (setq operation (plist-put operation :phase 'remote-applied))
    (ticktick--journal-put operation)
    ;; A network call may have allowed an Org edit while Emacs was waiting.
    (unless (memq action '(delete-local delete-remote)) (ticktick--check-local-version operation))
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
      (when (and id (not (plist-get theirs :unknown))
                 (ticktick--snapshots-equivalent-p target (plist-get theirs :snapshot))
                 (or (equal (plist-get ours :snapshot) target)
                     (equal (plist-get ours :snapshot) (plist-get operation :local))))
        (when target (setq target (plist-get theirs :snapshot)))
        (if target
            (ticktick--write-local-snapshot (plist-get ours :key) id target)
          (when ours (ticktick--remove-local-task id)))
        (ticktick--finish-operation operation id target)))))

(defun ticktick--run-sync (&optional direction)
  "Reconcile tasks, optionally limiting writes to DIRECTION (pull or push)."
  (when ticktick--sync-in-progress (user-error "TickTick sync already running"))
  (let ((ticktick--sync-in-progress t))
    (ticktick--ensure-state-initialized)
    (ticktick--recover-file-moves)
    (let* ((local (ticktick--collect-local-records))
           (remote (ticktick--collect-remote-records local)))
      (ticktick--remember-sync-files)
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
             (pending
              (setq operation (plist-put operation :pending-intent pending))
              (when (plist-get pending :replaces-id)
                (setq operation (plist-put operation :replaces-id (plist-get pending :replaces-id))))
              (when (eq (plist-get pending :action) 'create)
                (setq operation (plist-put operation :action 'create)))
              (push operation conflicts))
             ((eq action 'conflict) (push operation conflicts))
             ((or (and (eq direction 'pull) (memq action '(push create delete-remote)))
                  (and (eq direction 'push) (memq action '(pull delete-local)))) nil)
             ((and direction (eq action 'merge))
              (push (plist-put operation :reason 'requires-full-sync) conflicts))
             ((and (memq action '(delete-local delete-remote))
                   (or (memq ticktick-delete-behavior '(ask sync-only))
                       (and (eq ticktick-delete-behavior 'archive) ticktick-confirm-deletions)))
              (push (plist-put operation :reason 'deletion-review) conflicts))
             (t
              (condition-case err
                  (ticktick--execute-operation operation)
                (error
                 (setq operation (plist-put operation :error (error-message-string err)))
                 (push operation conflicts)))))))
        (setq ticktick--sync-state (plist-put ticktick--sync-state :conflicts (nreverse conflicts)))
        (setq ticktick--sync-state
              (plist-put ticktick--sync-state :org-task-ids
                         (delq nil (mapcar (lambda (record) (plist-get record :id))
                                          (ticktick--collect-local-records)))))
        (setq ticktick--sync-state
              (plist-put ticktick--sync-state :task-project-map (ticktick--collect-task-project-map)))
        (setq ticktick--sync-state (plist-put ticktick--sync-state :last-sync-time (format-time-string "%FT%T%z")))
        (ticktick--save-state)
        (message "TickTick: sync finished; %d task(s) need review" (length conflicts))))))

(defun ticktick--conflict (key)
  "Find the recorded conflict for KEY."
  (or (cl-find key (plist-get ticktick--sync-state :conflicts)
               :key (lambda (op) (plist-get op :key)) :test #'equal)
      (user-error "Conflict no longer exists; refresh the review")))

(defun ticktick--remove-conflict (key)
  "Remove the resolved conflict identified by KEY and persist state."
  (setq ticktick--sync-state
        (plist-put ticktick--sync-state :conflicts
                   (cl-remove key (plist-get ticktick--sync-state :conflicts)
                              :key (lambda (op) (plist-get op :key)) :test #'equal)))
  (ticktick--save-state))

(defun ticktick--call-with-sync-lock (function &rest arguments)
  "Call FUNCTION with ARGUMENTS while preventing nested sync mutations."
  (when ticktick--sync-in-progress (user-error "TickTick sync already running"))
  (let ((ticktick--sync-in-progress t)) (apply function arguments)))

(defun ticktick-resolve-conflict (key choice &optional edited reviewed)
  "Resolve KEY using CHOICE and optional EDITED task under the sync lock.
REVIEWED, when supplied by the UI, is the exact version the user saw."
  (ticktick--call-with-sync-lock #'ticktick--resolve-conflict key choice edited reviewed))

(defun ticktick--resolve-conflict (key choice &optional edited reviewed)
  "Resolve KEY using CHOICE (org, ticktick, or edited snapshot EDITED).
Recheck both source versions before applying the decision."
  (let* ((conflict (or reviewed (ticktick--conflict key)))
         (pending (cl-find key (plist-get ticktick--sync-state :pending-operations)
                           :key (lambda (op) (plist-get op :key)) :test #'equal)))
    (when (and pending (eq (plist-get pending :action) 'create)
               (not (plist-get pending :created-id)))
      (user-error "Creation outcome unknown: attach its ID or verify failure before retrying"))
    (when (plist-get (plist-get conflict :remote-record) :unknown)
      (user-error "Restore access to the project before resolving this task"))
    (ticktick--check-local-version conflict)
    (ticktick--check-remote-version conflict)
    (let* ((target (pcase choice
                     ('org (plist-get conflict :local))
                     ('ticktick (plist-get conflict :remote))
                     ('edited edited)
                     ('delete nil)
                     (_ (user-error "Unknown resolution choice"))))
           (operation (copy-tree conflict)))
      (setf (plist-get operation :target) target
            (plist-get operation :action)
            (cond ((not target) (if (plist-get conflict :remote) 'delete-remote 'delete-local))
                  ((not (plist-get conflict :remote)) 'create)
                  ((equal target (plist-get conflict :remote)) 'pull)
                  (t 'push)))
      (when (and target (not (plist-get conflict :remote)))
        (setf (plist-get operation :replaces-id) (plist-get conflict :id)))
      (ticktick--execute-operation operation)
      (ticktick--remove-conflict key))))

(defun ticktick-link-pending-creation (key id)
  "Attach remote task ID to an uncertain creation identified by KEY."
  (interactive
   (list (completing-read "Pending creation: "
                          (mapcar (lambda (op) (plist-get op :key))
                                  (plist-get ticktick--sync-state :pending-operations)) nil t)
         (read-string "Created TickTick task ID: ")))
  (ticktick--call-with-sync-lock #'ticktick--link-pending-creation key id))

(defun ticktick--link-pending-creation (key id)
  "Finish linking KEY to remote ID while holding the sync lock."
  (let* ((operation (cl-find key (plist-get ticktick--sync-state :pending-operations)
                             :key (lambda (op) (plist-get op :key)) :test #'equal))
         (target (plist-get operation :target))
         (remote (ticktick--read-remote-task id (plist-get target :project-id))))
    (unless (and (eq (plist-get operation :action) 'create)
                 (equal target (plist-get remote :snapshot)))
      (user-error "Remote task does not match the pending creation"))
    (setf (plist-get operation :created-id) id)
    (ticktick--journal-put operation)
    (let ((local (ticktick--local-record key)))
      (if (equal (plist-get local :snapshot) (plist-get operation :local))
          (progn
            (ticktick--write-local-snapshot key id target)
            (ticktick--finish-operation operation id target)
            (ticktick--remove-conflict key))
        ;; Establish identity without overwriting edits made while creation
        ;; was uncertain.  The user can now choose either current version.
        (setq ticktick--sync-state
              (plist-put ticktick--sync-state :conflicts
                         (cons (list :id id :key key :base target
                                     :local (plist-get local :snapshot)
                                     :remote (plist-get remote :snapshot)
                                     :local-record local :remote-record remote
                                     :pending-intent operation :action 'conflict)
                               (cl-remove key (plist-get ticktick--sync-state :conflicts)
                                          :key (lambda (op) (plist-get op :key)) :test #'equal))))
        (ticktick--save-state)
        (message "TickTick: creation linked; review subsequent local changes")))))

(defun ticktick-retry-pending-creation (key)
  "Release uncertain creation KEY only after explicit verification of failure."
  (interactive
   (list (completing-read "Pending creation: "
                          (mapcar (lambda (op) (plist-get op :key))
                                  (plist-get ticktick--sync-state :pending-operations)) nil t)))
  (when ticktick--sync-in-progress (user-error "TickTick sync already running"))
  (let ((operation (cl-find key (plist-get ticktick--sync-state :pending-operations)
                            :key (lambda (op) (plist-get op :key)) :test #'equal)))
    (unless (and (eq (plist-get operation :action) 'create)
                 (not (plist-get operation :created-id)))
      (user-error "This is not an uncertain creation"))
    (when (yes-or-no-p "Have you verified in TickTick that this task was NOT created? ")
      (setq ticktick--sync-state
            (plist-put ticktick--sync-state :pending-operations
                       (delq operation (plist-get ticktick--sync-state :pending-operations))))
      (ticktick--remove-conflict key)
      (message "TickTick: creation may be retried on the next sync"))))

(defvar-local ticktick--editing-conflict-key nil
  "Conflict being edited in the current buffer.")

(defvar-local ticktick--editing-conflict-record nil
  "Exact source versions shown when the current merge editor opened.")

(defvar ticktick-conflict-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map org-mode-map)
    (define-key map (kbd "C-c C-c") #'ticktick-conflict-edit-save)
    (define-key map (kbd "C-c C-k") #'kill-current-buffer)
    map)
  "Keys for editing a conflict resolution.")

(define-derived-mode ticktick-conflict-edit-mode org-mode "TickTick Merge"
  "Edit a task; C-c C-c applies the resolution and C-c C-k cancels.")

(defun ticktick-edit-conflict (key)
  "Open an editable Org representation of conflict KEY."
  (let* ((conflict (ticktick--conflict key))
         (snapshot (or (plist-get conflict :local) (plist-get conflict :remote))))
    (unless snapshot (user-error "No surviving task to edit"))
    (pop-to-buffer (generate-new-buffer "*TickTick Merge*"))
    (ticktick-conflict-edit-mode)
    (setq ticktick--editing-conflict-key key
          ticktick--editing-conflict-record (copy-tree conflict))
    (insert "* Project\n:PROPERTIES:\n:TICKTICK_PROJECT_ID: "
            (plist-get snapshot :project-id) "\n:END:\n")
    (let ((task (list :id (plist-get conflict :id)
                      :title (plist-get snapshot :title)
                      :content (plist-get snapshot :content)
                      :status (plist-get snapshot :status)
                      :priority (plist-get snapshot :priority)
                      :tags (plist-get snapshot :tags))))
      (insert (ticktick--task-to-heading task) "\n"))
    (goto-char (point-min))
    (re-search-forward "^\\*\\* ") (beginning-of-line)
    (let* ((deadline (plist-get snapshot :deadline))
           (value (plist-get deadline :value)))
      (when value
        (org-deadline nil (if (plist-get deadline :all-day) value
                           (format-time-string "%F %a %H:%M" (date-to-time value)))))
      (when value (org-entry-put nil "TICKTICK_DUE_VALUE" value))
      (when (plist-get deadline :time-zone)
        (org-entry-put nil "TICKTICK_TIME_ZONE" (plist-get deadline :time-zone))))
    (set-buffer-modified-p nil)
    (message "Edit the task; C-c C-c applies, C-c C-k cancels")))

(defun ticktick-conflict-edit-save ()
  "Apply the edited task after rechecking the reviewed source versions."
  (interactive)
  (unless ticktick--editing-conflict-key (user-error "No conflict in this buffer"))
  (let ((key ticktick--editing-conflict-key)
        (buffer (current-buffer)))
    (goto-char (point-min))
    (unless (re-search-forward "^\\*\\* " nil t) (user-error "Keep a task heading"))
    (beginning-of-line)
    (ticktick-resolve-conflict key 'edited (ticktick--snapshot-from-org)
                               ticktick--editing-conflict-record)
    (set-buffer-modified-p nil)
    (kill-buffer buffer)
    (ticktick-review-conflicts)))

(define-derived-mode ticktick-conflicts-mode special-mode "TickTick Conflicts"
  "Review conflicts; g refreshes synchronization and q closes the buffer.")

(define-key ticktick-conflicts-mode-map (kbd "g") #'ticktick-refresh-conflicts)

(defun ticktick-refresh-conflicts ()
  "Refresh task snapshots and rebuild the conflict review."
  (interactive)
  (ticktick-sync)
  (ticktick-review-conflicts))

;;;###autoload
(defun ticktick-review-conflicts ()
  "Display recorded conflicts with explicit choices; never prompt during autosync."
  (interactive)
  (require 'pp)
  (require 'button)
  (ticktick--ensure-state-initialized)
  (let ((conflicts (plist-get ticktick--sync-state :conflicts)))
    (pop-to-buffer (get-buffer-create "*TickTick Conflicts*"))
    (ticktick-conflicts-mode)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "TickTick conflicts\n\ng: fetch fresh versions    q: close\n\n")
      (unless conflicts (insert "No unresolved conflicts.\n"))
      (dolist (conflict conflicts)
        (let ((key (plist-get conflict :key))
              (reviewed (copy-tree conflict)))
          (insert (format "Task: %s [%s]\n"
                          (or (plist-get (plist-get conflict :local) :title)
                              (plist-get (plist-get conflict :remote) :title) key) key))
          (when (plist-get conflict :conflicting-fields)
            (insert (format "Conflicting fields: %s\n" (plist-get conflict :conflicting-fields))))
          (when (plist-get conflict :pending-intent)
            (insert (format "Interrupted intent:\n%s\n"
                            (pp-to-string (plist-get (plist-get conflict :pending-intent) :target)))))
          (when (plist-get conflict :reason)
            (insert (format "Review reason: %s\n" (plist-get conflict :reason))))
          (when (plist-get conflict :error)
            (insert (format "Last error: %s\n" (plist-get conflict :error))))
          (dolist (version '(("Base" . :base) ("Org" . :local) ("TickTick" . :remote)))
            (insert (format "%s:\n%s\n" (car version)
                            (pp-to-string (plist-get conflict (cdr version))))))
          (dolist (choice '(("Use Org" . org) ("Use TickTick" . ticktick)))
            (let ((decision (cdr choice)))
              (insert-text-button
               (car choice) 'follow-link t
               'action (lambda (_)
                         (ticktick-resolve-conflict key decision nil reviewed)
                         (ticktick-review-conflicts)))
              (insert "   ")))
          (insert-text-button "Edit merged task" 'follow-link t
                              'action (lambda (_) (ticktick-edit-conflict key)))
          (insert "   ")
          (insert-text-button "Delete both copies" 'follow-link t
                              'action (lambda (_)
                                        (ticktick-resolve-conflict key 'delete nil reviewed)
                                        (ticktick-review-conflicts)))
          (insert "\nDefer: leave this task unresolved.\n")
          (when (eq (plist-get conflict :action) 'create)
            (insert-text-button "Attach created task ID" 'follow-link t
                                'action (lambda (_)
                                          (ticktick-link-pending-creation key (read-string "Task ID: "))
                                          (ticktick-review-conflicts)))
            (insert "   ")
            (insert-text-button "Verified creation failed: allow retry" 'follow-link t
                                'action (lambda (_)
                                          (ticktick-retry-pending-creation key)
                                          (ticktick-review-conflicts)))
            (insert "\n"))
          (insert "\n")))
      (goto-char (point-min)))))

(provide 'ticktick-reconcile)
;;; ticktick-reconcile.el ends here
