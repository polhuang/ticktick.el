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
        nil 'file)))
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
                         (plist-get ticktick--sync-state :api-task-ids))))
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
                               (ticktick--get-cached-project-id id)))
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
      (setf (plist-get (car plan) :id) (or (plist-get (car plan) :id) key)
            (plist-get (car plan) :key) key))
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

(provide 'ticktick-reconcile)
;;; ticktick-reconcile.el ends here
