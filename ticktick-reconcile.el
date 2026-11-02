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

(provide 'ticktick-reconcile)
;;; ticktick-reconcile.el ends here
