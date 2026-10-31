<#
Read paper-space viewport view centres, which COM does not expose, by sending one read-only AutoLISP expression.
Writes "handle|centre(DXF 12)|viewHeight(45)|target(17)|twist(51)" lines to -OutFile and prints them.
Model view centre = target + centre for untwisted plan views.

  .\get-viewport-centres.ps1 -Expected <exact drawing path> -OutFile vp.txt -Handles 2A1B,2A2C
#>
param([Parameter(Mandatory)][string]$Expected, [Parameter(Mandatory)][string]$OutFile, [Parameter(Mandatory)][string[]]$Handles,
    [string]$ProgId = 'AutoCAD.Application.25')
$ErrorActionPreference = 'Stop'
$acad = [Runtime.InteropServices.Marshal]::GetActiveObject($ProgId)
try {
    $doc = $acad.ActiveDocument
    if ($doc.FullName -ne $Expected) { throw "Active drawing is $($doc.FullName)" }
    if (Test-Path $OutFile) { Remove-Item $OutFile }
    $path = $OutFile.Replace('\', '/')
    $hs = ($Handles | ForEach-Object { "`"$_`"" }) -join ' '
    $lisp = "(progn (setq f (open `"$path`" `"w`")) (foreach h '($hs) (setq e (entget (handent h))) (write-line (strcat h `"|`" (vl-princ-to-string (cdr (assoc 12 e))) `"|`" (rtos (cdr (assoc 45 e)) 2 4) `"|`" (vl-princ-to-string (cdr (assoc 17 e))) `"|`" (rtos (cdr (assoc 51 e)) 2 4)) f)) (close f) (princ))`n"
    $doc.SendCommand($lisp)
    for ($i = 0; $i -lt 40 -and -not (Test-Path $OutFile); $i++) { Start-Sleep -Milliseconds 250 }
    Start-Sleep -Milliseconds 300
    Get-Content $OutFile
}
finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($acad) }
