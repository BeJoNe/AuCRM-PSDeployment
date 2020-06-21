$executionSteps = @(
    @{
        "testserver-1" = @{
            JobName = "Deploy_Test1";
            ScriptName = "Deploy"
        };
        "testserver-2" = @{
            JobName = "Deploy_Test2";
            ScriptName = "Deploy"
        }
    }
)

foreach($step in $executionSteps)
{
    $resultJobs = @();
    foreach($stepKey in ([HashTable] $step).Keys | Where-Object { ([HashTable] $step[$_]).Count -gt 0 })
    {
        $scriptName = $step[$stepKey].ScriptName
        [ScriptBlock] $transportInvoke = { param([string] $scriptName) ; . ("C:\AuCRM-PSDeployment\{0}.ps1" -f $scriptName) }

        $resultJobs += Invoke-Command -ComputerName $stepKey `
            -AsJob `
            -JobName $step[$stepKey].JobName `
            -ScriptBlock $transportInvoke `
            -ArgumentList @($scriptName) `
            -Authentication Default `
            -ErrorAction Stop

        # (Get-Job | ? { $_.Name -eq $step[$stepKey].JobName })
    }
    If($resultJobs.Count -lt 1) { Continue }
    
    # Wait-Job -Job $resultJobs | Out-Null
    Write-Host -ForegroundColor Yellow ("Starting executing jobs on: {0}" -f ((([HashTable] $step).Keys) -join ","))
    
    Receive-Job -Job $resultJobs -Wait `
        | ForEach-Object { Write-Host -ForegroundColor Cyan "Result of executions: $($_)" }
    
    # Clean-up all
    Get-Job `
        | Where-Object { $_.Location -in ([HashTable] $step).Keys } `
        | ForEach-Object { Remove-Job -Job $_ }
}