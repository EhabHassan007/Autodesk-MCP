;; Smart Autodesk Connector commands behind the buttons on the AutoCAD Add-ins tab.
;; Each command starts a hidden PowerShell that shows its own branded window, so AutoCAD stays free.
;; Loaded per document by PackageContents.xml; safe to load more than once.

(defun sac:root () (strcat (getenv "LOCALAPPDATA") "\\BIM-CAD-MCP"))

(defun sac:powershell () (strcat (getenv "SystemRoot") "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"))

(defun sac:run (script arguments / file)
  (setq file (strcat (sac:root) "\\installer\\" script))
  (if (findfile file)
    (if (startapp (sac:powershell)
          (strcat "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" file "\" " arguments))
      (princ "\nSmart Autodesk Connector: the window opens in a moment.")
      (princ "\nSmart Autodesk Connector: PowerShell could not be started."))
    (princ "\nSmart Autodesk Connector is not installed for this user. Run its setup again."))
  (princ))

(defun c:SACSKILLSSYNC () (sac:run "ConnectorActions.ps1" "-Action SkillsSync"))
(defun c:SACCHECKUPDATES () (sac:run "ConnectorActions.ps1" "-Action CheckUpdates"))
(defun c:SACSETTINGS () (sac:run "Settings.ps1" ""))
(defun c:SACSTATUS () (sac:run "ConnectorActions.ps1" "-Action Status"))

(princ)
