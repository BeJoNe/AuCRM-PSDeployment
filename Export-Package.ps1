param([switch] $UserInvoke)
Set-Location $(Split-Path $MyInvocation.MyCommand.Definition)

$global:Platform = "DEV"
. .\shared\transportlib.ps1

BootStrap

Transport-Logic

Finalizing -OutputIntoDest

If($UserInvoke) { cmd /c pause }