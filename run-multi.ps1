# A local test session: a dedicated server and two clients that join it (straight to the login
# screen, the server's address filled in). Godot binary: $env:GODOT, or the path below.
Set-Location $PSScriptRoot
$g = if ($env:GODOT) { $env:GODOT } else { "C:\SDK\godot\Godot_v4.7.2-stable_win64.exe" }

Start-Process $g -ArgumentList '--headless --path . -- --server'
Start-Process $g -ArgumentList '--path . -- --join=127.0.0.1'
Start-Process $g -ArgumentList '--path . -- --join=127.0.0.1'
