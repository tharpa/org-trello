;;; org-trello-cbx.el --- Manipulation functions of checkbox to add some behavior to org's checkbox
;;; Commentary:
;;; Code:

(require 'org-trello-setup)
(require 'org-trello-log)
(require 'org-trello-hash)
(require 'org-trello-entity)
(require 's)

(defun orgtrello-cbx/serialize-hashmap (hash-table)
  "Return a json representation of HASH-TABLE."
  (json-encode-hash-table hash-table))

(defun orgtrello-cbx/--to-properties (alist)
  "Serialize an ALIST to json."
  (-> alist
    orgtrello-hash/make-properties
    orgtrello-cbx/serialize-hashmap))

(defun orgtrello-cbx/--from-properties (string)
  "Deserialize STRING from json to list."
  (when string (json-read-from-string string)))

(defun orgtrello-cbx/--checkbox-split (checkbox-content)
  "Split the checkbox CHECKBOX-CONTENT into the checkbox data and the checkbox metadata."
  (s-split ":PROPERTIES:" checkbox-content))

(defun orgtrello-cbx/--checkbox-metadata (checkbox-content)
  "Retrieve the checkbox's metadata from the CHECKBOX-CONTENT."
  (-when-let (res (-> checkbox-content
                    orgtrello-cbx/--checkbox-split
                    cadr))
    (s-trim-left res)))

(defun orgtrello-cbx/--checkbox-data (checkbox-content)
  "Retrieve the checkbox's data from the CHECKBOX-CONTENT."
  (-> checkbox-content
    orgtrello-cbx/--checkbox-split
    car
    s-trim-right))

(defun orgtrello-cbx/--read-properties (string)
  "Read the properties from the current STRING."
  (->> string
    orgtrello-cbx/--checkbox-metadata
    orgtrello-cbx/--from-properties))

(defun orgtrello-cbx/--read-checkbox! ()
  "Read the full checkbox's content"
  (buffer-substring-no-properties (point-at-bol) (point-at-eol)))

(defun orgtrello-cbx/--read-properties-from-point (pt)
  "Read the properties from the point PT."
  (save-excursion
    (goto-char pt)
    (orgtrello-cbx/--read-properties (orgtrello-cbx/--read-checkbox!))))

(defun orgtrello-cbx/--make-properties-as-string (properties)
  "Serialize the PROPERTIES to checkbox string."
  (format ":PROPERTIES: %s" (orgtrello-cbx/--to-properties properties)))

(defun orgtrello-cbx/remove-overlays! (start end)
  "Remove the overlays presents between START and END in the current buffer"
  (remove-overlays start end 'invisible 'org-trello-cbx-property))

(defun orgtrello-cbx/install-overlays! (start-position)
  "Install org-trello overlays from START-POSITION.
First, it removes the current overlay on line and then install the new."
  ;; remove overlay present on current position
  (orgtrello-cbx/remove-overlays! (point-at-bol) (point-at-eol))
  ;; build an overlay to hide the cbx properties
  (overlay-put (make-overlay start-position (point-at-eol) (current-buffer) t nil)
               'invisible 'org-trello-cbx-property))

(defun orgtrello-cbx/--write-properties-at-point (pt properties)
  "Overwrite the current properties at point PT with new PROPERTIES."
  (save-excursion
    (goto-char pt)
    (let* ((checkbox-title   (-> (orgtrello-cbx/--read-checkbox!) orgtrello-cbx/--checkbox-data))
           (updated-property (orgtrello-cbx/--make-properties-as-string properties))
           (text-to-insert   (format "%s %s" checkbox-title updated-property)))
      (beginning-of-line)
      (kill-line)
      (insert text-to-insert)
      text-to-insert)))

(defun orgtrello-cbx/--key-to-search (key)
  "Search the KEY as a symbol."
  (if (stringp key) (intern key) key))

(defun orgtrello-cbx/--org-get-property (key properties)
  "Retrieve the value at KEY in PROPERTIES."
  (-> key
    orgtrello-cbx/--key-to-search
    (assoc-default properties)))

(defun orgtrello-cbx/--org-update-property (key value properties)
  "Update the KEY with VALUE in PROPERTIES."
  (->> properties
    (orgtrello-cbx/--org-delete-property key)
    (cons `(,(orgtrello-cbx/--key-to-search key) . ,value))))

(defun orgtrello-cbx/--org-delete-property (key properties)
  "Delete the KEY from the PROPERTIES."
  (-> key
    orgtrello-cbx/--key-to-search
    (assq-delete-all properties)))

(defun orgtrello-cbx/org-set-property (key value)
  "Add the new property KEY with VALUE.
Write the new properties at current position."
  (let ((current-point (point)))
    (->> current-point
      orgtrello-cbx/--read-properties-from-point
      (orgtrello-cbx/--org-update-property key value)
      (orgtrello-cbx/--write-properties-at-point current-point))))

(defun orgtrello-cbx/org-get-property (point key)
  "Retrieve the value at POINT with property KEY."
  (->> point
    orgtrello-cbx/--read-properties-from-point
    (orgtrello-cbx/--org-get-property key)))

(defun orgtrello-cbx/org-delete-property (key)
  "Delete the property KEY from the properties."
  (let ((current-point (point)))
    (->> current-point
      orgtrello-cbx/--read-properties-from-point
      (orgtrello-cbx/--org-delete-property key)
      (orgtrello-cbx/--write-properties-at-point current-point))))

(defun orgtrello-cbx/--org-split-data (string)
  "Split the STRING into meta data with -."
  (->> string
    (s-replace "[ ]" "[]")
    (s-split " ")))

(defun orgtrello-cbx/--retrieve-status (metadata)
  "Given a list of METADATA, return the status."
  (car (--drop-while (not (or (string= "[]" it)
                              (string= "[X]" it)
                              (string= "[-]" it)
                              (string= "[ ]" it))) metadata)))

(defun orgtrello-cbx/--status (status)
  "Given a checklist STATUS, return the TODO/DONE for org-trello to work."
  (if (string= "[X]" status) *ORGTRELLO/DONE* *ORGTRELLO/TODO*))

(defun orgtrello-cbx/--name (s status)
  "Retrieve the name of the checklist from the checkbox content S and its STATUS."
  (->> s
    (s-replace "[ ]" "[]")
    s-trim-left
    (s-chop-prefix "-")
    s-trim-left
    (s-chop-prefix status)
    s-trim))

(defun orgtrello-cbx/--metadata-from-checklist (full-checklist)
  "Given a FULL-CHECKLIST string, extract the list of metadata."
  (let* ((checklist-data   (orgtrello-cbx/--checkbox-data full-checklist))
         (meta             (orgtrello-cbx/--org-split-data checklist-data))
         (status-retrieved (orgtrello-cbx/--retrieve-status meta)))
    (list nil (orgtrello-cbx/--status status-retrieved) nil (orgtrello-cbx/--name checklist-data status-retrieved) nil)))

(defun orgtrello-cbx/org-checkbox-metadata! ()
  "Extract the metadata about the checklist - this is the symmetrical with `org-heading-components` but for the checklist.
Return the components of the current heading.
This is a list with the following elements:
- the level as an integer                                          - (begins at 2)
- the reduced level                                                - always nil
- the TODO keyword, or nil                                         - [], [-] map to TODO, [X] map to DONE
- the priority character, like ?A, or nil if no priority is given  - nil
- the headline text itself, or the tags string if no headline text - the name of the checkbox
- the tags string, or nil.                                         - nil"
  (save-excursion
    (beginning-of-line)
    (cons (orgtrello-entity/level!)
          (orgtrello-cbx/--metadata-from-checklist (orgtrello-cbx/--read-checkbox!)))))

(defun orgtrello-cbx/--get-level (meta)
  "Retrieve the level from the META describing the checklist."
  (car meta))

(defun orgtrello-cbx/--org-up! (destination-level)
  "A function to get back to the current entry's DESTINATION-LEVEL ancestor.
Return the level found or nil if the level found is a card."
  (let ((current-level (orgtrello-cbx/--get-level (orgtrello-cbx/org-checkbox-metadata!))))
    (cond ((= *ORGTRELLO/CARD-LEVEL* current-level)      nil)
          ((= destination-level current-level)           destination-level)
          ((= *ORGTRELLO/CHECKLIST-LEVEL* current-level) (org-up-heading-safe))
          (t                                             (progn
                                                           (forward-line -1)
                                                           (orgtrello-cbx/--org-up! destination-level))))))

(defun orgtrello-cbx/current-level! ()
  "Give the current level of the checkbox."
  (orgtrello-cbx/--get-level (orgtrello-cbx/org-checkbox-metadata!)))

(defun orgtrello-cbx/org-up! ()
  "A function to get back to the current entry's parent."
  (-> (orgtrello-cbx/current-level!)
    1-
    orgtrello-cbx/--org-up!))

(defun orgtrello-cbx/--map-checkboxes (level fn-to-execute)
  "Map over the checkboxes with level > to LEVEL and execute FN-TO-EXECUTE.
Does not preserve the cursor position.
Do not exceed the max size of buffer."
  (let ((current-point (point-at-eol)))
    (orgtrello-entity/goto-next-checkbox)
    (let ((new-pt (point-at-eol)))
      (when (and (not (= current-point new-pt)) (< level (orgtrello-entity/level!)))
        (funcall fn-to-execute)
        (orgtrello-cbx/--map-checkboxes level fn-to-execute)))))

(defun orgtrello-cbx/map-checkboxes (fn-to-execute)
  "Map over the current checkbox and execute FN-TO-EXECUTE."
  (save-excursion
    (orgtrello-entity/back-to-card!)                                 ;; go back to the card
    (-when-let (fst-cbx (orgtrello-entity/goto-next-checkbox-with-same-level! *ORGTRELLO/CHECKLIST-LEVEL*))
      (goto-char fst-cbx)                                            ;; then first checklist
      (funcall fn-to-execute)                                        ;; execute the function on it
      (orgtrello-cbx/--map-checkboxes *ORGTRELLO/CARD-LEVEL* fn-to-execute))))

(orgtrello-log/msg *OT/DEBUG* "orgtrello-cbx loaded!")

(provide 'org-trello-cbx)
;;; org-trello-cbx.el ends here
