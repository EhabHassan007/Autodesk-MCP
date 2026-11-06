;; Smart Connector commands behind the buttons on the AutoCAD Add-ins tab.
;; Each command starts a hidden PowerShell that shows its own branded window, so AutoCAD stays free.
;; Demand-loaded by PackageContents.xml when one of these commands is first used; safe to load more than once.
;; (Loading at AutoCAD startup is avoided on purpose: AutoCAD asked SECURELOAD for every drawing.)
;;
;; Once per AutoCAD session, from the first Smart Connector button used, it also runs the daily check that
;; Revit and the Smart Connector app run when they open. Nothing runs outside AutoCAD and nothing is
;; scheduled; the person answers each question.
;;  - Update check: at most once a day (shared with Revit and the app), unless switched off in Settings. One
;;    small download of the public release manifest, made in the background while you work. When a newer
;;    version exists: "Update now?" Yes opens the update window, which installs once Revit and AutoCAD close.
;;  - Skills Sync reminder: on team computers with the reminder on, when the last successful Skills Sync is
;;    more than a week old, at most once a day: "Sync now?"
;; The work happens after commands finish, and the download never makes AutoCAD wait.
;; Day stamps (days since 1970-01-01, as text) are the files the Revit add-in and the app use as well.

(defun sac:root () (strcat (getenv "LOCALAPPDATA") "\\BIM-CAD-MCP"))

(defun sac:powershell () (strcat (getenv "SystemRoot") "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"))

(defun sac:run (script arguments / file)
  (setq file (strcat (sac:root) "\\installer\\" script))
  (if (findfile file)
    (if (startapp (sac:powershell)
          (strcat "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" file "\" " arguments))
      (princ "\nSmart Connector: the window opens in a moment.")
      (princ "\nSmart Connector: PowerShell could not be started."))
    (princ "\nSmart Connector is not installed for this user. Run its setup again."))
  (princ))

(defun c:SACOPEN () (sac:run "SmartConnectorApp.ps1" "-Section Overview"))
;; Running Skills Sync or Check Updates by hand answers today's reminder or update question.
(defun c:SACSKILLSSYNC ()
  (setq sacs:*sync-due* nil)
  (sacs:stamp (sacs:skills-file "sync-reminder.txt"))
  (sac:run "ConnectorActions.ps1" "-Action SkillsSync"))
(defun c:SACCHECKUPDATES ()
  (if (not sacs:*download-started*) (setq sacs:*check-update* nil))
  (sacs:stamp (sacs:connector-file "open-check.txt"))
  (sac:run "ConnectorActions.ps1" "-Action CheckUpdates"))
(defun c:SACSETTINGS () (sac:run "SmartConnectorApp.ps1" "-Section Settings"))
(defun c:SACSTATUS () (sac:run "ConnectorActions.ps1" "-Action Status"))

;; ---------- daily check ----------

(vl-load-com)

(defun sacs:local (folder) (strcat (getenv "LOCALAPPDATA") "\\" folder))
(defun sacs:connector-file (name) (strcat (sacs:local "AutodeskMcpConnector") "\\" name))
(defun sacs:skills-file (name) (strcat (sacs:local "AutodeskMcpSkillCollection") "\\" name))
(defun sacs:install-file (name) (strcat (sacs:local "BIM-CAD-MCP") "\\" name))
(setq sacs:*manifest* "https://github.com/EhabHassan007/Autodesk-MCP-Releases/releases/latest/download/latest.json")

(defun sacs:read (path / file line text)
  (if (and path (findfile path) (setq file (open path "r")))
    (progn
      (setq text "")
      (while (setq line (read-line file)) (setq text (strcat text line "\n")))
      (close file)
      text)))

(defun sacs:write (path text / file)
  (if (setq file (open path "w"))
    (progn (write-line text file) (close file))))

;; Days since 1970-01-01. DATE is local time; the stamps are UTC, which is close enough for "once a day".
(defun sacs:today () (- (getvar "DATE") 2440587.5))
(defun sacs:day (path / text) (if (setq text (sacs:read path)) (atof text) -1.0))
(defun sacs:stamp (path) (sacs:write path (rtos (sacs:today) 2 3)))

;; The value after "key": in a flat JSON text, without quotes; nil when the key is missing.
(defun sacs:json (text key / at rest end)
  (if (and text (setq at (vl-string-search (strcat "\"" key "\"") text)))
    (progn
      (setq rest (vl-string-left-trim " \t\r\n:" (substr text (+ at (strlen key) 3))))
      (if (= (substr rest 1 1) "\"")
        (progn
          (setq rest (substr rest 2))
          (if (setq end (vl-string-search "\"" rest)) (substr rest 1 end)))
        (progn
          (setq end 0)
          (while (and (< end (strlen rest))
                      (not (member (substr rest (1+ end) 1) '("," "}" "\n" "\r" " " "\t"))))
            (setq end (1+ end)))
          (substr rest 1 end))))))

(defun sacs:split (text separator / at parts)
  (while (setq at (vl-string-search separator text))
    (setq parts (cons (substr text 1 at) parts)
          text (substr text (+ at 2))))
  (reverse (cons text parts)))

;; T when version a is newer than version b: 1.2.0 > 1.2.0-beta.3 > 1.1.9.
(defun sacs:newer (a b / pa pb ca cb diff i)
  (setq pa (sacs:split (vl-string-trim " \t\r\nvV" a) "-")
        pb (sacs:split (vl-string-trim " \t\r\nvV" b) "-")
        ca (mapcar 'atoi (sacs:split (car pa) "."))
        cb (mapcar 'atoi (sacs:split (car pb) "."))
        diff 0
        i 0)
  (while (and (= diff 0) (< i 3))
    (setq diff (- (if (nth i ca) (nth i ca) 0) (if (nth i cb) (nth i cb) 0))
          i (1+ i)))
  (cond ((> diff 0) T)
        ((< diff 0) nil)
        ((and (cdr pb) (not (cdr pa))) T)
        (T nil)))

;; A Yes/No question in front of AutoCAD; T for Yes.
(defun sacs:ask (title text / shell answer)
  (setq answer
    (vl-catch-all-apply
      '(lambda ()
         (setq shell (vlax-create-object "WScript.Shell"))
         (vlax-invoke-method shell 'Popup text 0 title (+ 4 32 4096)))))
  (if shell (vl-catch-all-apply 'vlax-release-object (list shell)))
  (and (not (vl-catch-all-error-p answer)) (= answer 6)))

;; Opens one of the Smart Connector windows (the person chose it).
(defun sacs:open-window (script arguments / file)
  (setq file (sacs:install-file (strcat "installer\\" script)))
  (if (findfile file)
    (startapp (strcat (getenv "SystemRoot") "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
      (strcat "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" file "\" " arguments))))

(defun sacs:update-due (/ state last)
  (setq state (sacs:read (sacs:connector-file "update-state.json"))
        last (sacs:day (sacs:connector-file "open-check.txt")))
  (and (findfile (sacs:install-file "VERSION"))
       (/= (sacs:json state "notifications_user_disabled") "true")
       (or (< last 0) (>= (- (sacs:today) last) 0.8))))

(defun sacs:sync-due (/ last reminded)
  (setq last (sacs:day (sacs:skills-file "last-sync.txt"))
        reminded (sacs:day (sacs:skills-file "sync-reminder.txt")))
  (and (findfile (sacs:skills-file "service.json"))
       (/= (sacs:json (sacs:read (sacs:skills-file "settings.json")) "enabled") "false")
       (or (< last 0) (>= (- (sacs:today) last) 7))
       (or (< reminded 0) (>= (- (sacs:today) reminded) 0.8))))

;; Starts the manifest download without waiting for it (asynchronous WinHTTP request).
(defun sacs:start-download (/ url result)
  (setq url (sacs:json (sacs:read (sacs:connector-file "update-state.json")) "release_manifest"))
  (if (not (and url (wcmatch (strcase url T) "https://*"))) (setq url sacs:*manifest*))
  (setq result
    (vl-catch-all-apply
      '(lambda ()
         (setq sacs:*request* (vlax-create-object "WinHttp.WinHttpRequest.5.1"))
         (vlax-invoke-method sacs:*request* 'SetTimeouts 5000 5000 5000 10000)
         (vlax-invoke-method sacs:*request* 'Open "GET" url :vlax-true)
         (vlax-invoke-method sacs:*request* 'SetRequestHeader "User-Agent" "SmartConnector-AutoCAD")
         (vlax-invoke-method sacs:*request* 'Send))))
  (if (vl-catch-all-error-p result) (sacs:drop-download)))

(defun sacs:drop-download ()
  (if sacs:*request* (vl-catch-all-apply 'vlax-release-object (list sacs:*request*)))
  (setq sacs:*request* nil))

;; The newer version from the finished download, "" when there is none, nil while it is still running.
(defun sacs:download-result (/ done text available installed)
  (setq done (vl-catch-all-apply 'vlax-invoke-method (list sacs:*request* 'WaitForResponse 0)))
  (cond
    ((vl-catch-all-error-p done) (sacs:drop-download) "")
    ((/= done :vlax-true) nil)
    (T
     (setq text (vl-catch-all-apply
                  '(lambda () (if (= (vlax-get-property sacs:*request* 'Status) 200) (vlax-get-property sacs:*request* 'ResponseText)))))
     (sacs:drop-download)
     (setq available (if (= (type text) 'STR) (sacs:json text "version"))
           installed (sacs:read (sacs:install-file "VERSION")))
     (if (and available installed (sacs:newer available installed)) available ""))))

(defun sacs:ask-sync (/ last)
  (sacs:stamp (sacs:skills-file "sync-reminder.txt"))
  (setq last (sacs:day (sacs:skills-file "last-sync.txt")))
  (if (sacs:ask "Smart Connector"
        (strcat (if (< last 0)
                  "Skills Sync has not run on this computer yet."
                  (strcat "Your last Skills Sync was " (itoa (fix (- (sacs:today) last))) " days ago."))
                "\n\nSync now? It sends your saved skills for review and downloads newly approved ones."
                "\n\nThe weekly reminder can be switched off in Smart Connector Settings."))
    (sacs:open-window "ConnectorActions.ps1" "-Action SkillsSync")))

(defun sacs:ask-update (available)
  (if (sacs:ask "Smart Connector"
        (strcat "Smart Connector " available " is available. You have version "
                (vl-string-trim " \t\r\n" (sacs:read (sacs:install-file "VERSION"))) "."
                "\n\nUpdate now? The update window opens: save your work and close AutoCAD and Revit, and it installs straight after."
                "\n\nChoose No to be asked again tomorrow."))
    (sacs:open-window "ConnectorActions.ps1" "-Action InstallUpdate")))

;; After each finished command until the work is done: start the download, then look at it; at most one
;; question per AutoCAD session, the update first.
(defun sacs:on-command-ended (reactor parameters / available)
  (vl-catch-all-apply
    '(lambda ()
       (setq sacs:*commands* (1+ sacs:*commands*))
       (cond
         ((and sacs:*check-update* (not sacs:*request*) (not sacs:*download-started*))
          (setq sacs:*download-started* T)
          (sacs:stamp (sacs:connector-file "open-check.txt"))
          (sacs:start-download)
          (if (not sacs:*request*) (setq sacs:*check-update* nil)))
         ((and sacs:*check-update* sacs:*request*)
          (setq available (sacs:download-result))
          (cond
            ((null available) (if (> sacs:*commands* 60) (progn (sacs:drop-download) (setq sacs:*check-update* nil))))
            ((/= available "") (setq sacs:*check-update* nil sacs:*sync-due* nil) (sacs:ask-update available))
            (T (setq sacs:*check-update* nil))))
         ((and (not sacs:*check-update*) sacs:*sync-due*)
          (setq sacs:*sync-due* nil)
          (sacs:ask-sync)))))
  (if (and (not sacs:*check-update*) (not sacs:*sync-due*) sacs:*reactor*)
    (progn (vlr-remove sacs:*reactor*) (setq sacs:*reactor* nil))))

(defun sacs:start (/ result)
  (setq result
    (vl-catch-all-apply
      '(lambda ()
         (if (not (vl-bb-ref 'sacs:*started*))
           (progn
             (vl-bb-set 'sacs:*started* T)
             (setq sacs:*check-update* (sacs:update-due)
                   sacs:*sync-due* (sacs:sync-due)
                   sacs:*commands* 0
                   sacs:*download-started* nil
                   sacs:*request* nil)
             (if (or sacs:*check-update* sacs:*sync-due*)
               (setq sacs:*reactor* (vlr-command-reactor nil '((:vlr-commandEnded . sacs:on-command-ended))))))))))
  (princ))

(sacs:start)
(princ)
