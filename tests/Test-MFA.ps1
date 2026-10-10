$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\lib\Client.ps1"
$mockChild = @'
$first = [Console]::ReadLine()
if ($first -ne 'fake-password') { exit 8 }
[Console]::Error.Write('Enter Your Microsoft veri')
[Threading.Thread]::Sleep(100)
[Console]::Error.WriteLine('fication code')
[Console]::Error.Write('Res')
[Threading.Thread]::Sleep(100)
[Console]::Error.Write('ponse:')
$code = [Console]::ReadLine()
if ($code -ne '123456') { exit 9 }
[Console]::WriteLine('MOCK_MFA_OK')
exit 0
'@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($mockChild))
$childPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$exit = Invoke-HKUClient -Client $childPath -ClientArguments @('-NoProfile', '-EncodedCommand', $encoded) -Password 'fake-password' -TotpProvider { '123456' }
if ($exit -ne 0) { throw "Mock MFA failed with exit $exit" }
Write-Output ('PowerShell ' + $PSVersionTable.PSVersion + ': split MFA prompt detection and automatic stdin submission OK.')
