param([switch] $UserInvoke)
Set-Location $(Split-Path $MyInvocation.MyCommand.Definition)

$global:Platform = "Test"
. .\shared\transportlib.ps1

BootStrap

Transport-Logic

Finalizing # -OutputIntoDest - only possible if remote folder is linked as symlink dir

If($UserInvoke) { cmd /c pause }