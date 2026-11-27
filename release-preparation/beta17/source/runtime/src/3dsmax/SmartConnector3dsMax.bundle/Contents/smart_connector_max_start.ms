-- Smart Connector bridge for 3ds Max. Loaded by PackageContents.xml as a post-start-up script.
-- Starts the local, owner-only pipe that SmartConnector.exe uses (python\smart_connector_max), and stops it before
-- 3ds Max shuts down. To switch the bridge off, create the empty file
-- %LOCALAPPDATA%\BIM-CAD-MCP\runtime\max-bridge-disabled and restart 3ds Max.
(
    local pythonFolder = pathConfig.appendPath (getFilenamePath (getThisScriptFilename())) "python"
    local folderText = substituteString pythonFolder "\\" "/"
    try
    (
        python.Execute ("import sys\nif r'" + folderText + "' not in sys.path: sys.path.insert(0, r'" + folderText + "')\nimport smart_connector_max.main as _scm\n_scm.start()")
        callbacks.removeScripts id:#SmartConnectorMax
        callbacks.addScript #preSystemShutdown "python.Execute \"import smart_connector_max.main as _scm\\n_scm.stop()\"" id:#SmartConnectorMax
    )
    catch
    (
        format "Smart Connector: the 3ds Max bridge did not start: %\n" (getCurrentException())
    )
)
