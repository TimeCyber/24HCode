param([string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'))
$ErrorActionPreference = 'Stop'
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
$content = [System.IO.File]::ReadAllText($resolvedConfig)
$section = '(?ms)(^\[mcp_servers\.codeassist\]\r?\n)(.*?)(?=^\[|\z)'
if (-not [regex]::IsMatch($content, $section)) { throw 'Missing mcp_servers.codeassist section' }
$updated = [regex]::Replace($content, $section, {
    param($match)
    $body = $match.Groups[2].Value
    if ($body -match '(?m)^tool_call_timeout_sec\s*=') {
        $body = [regex]::Replace($body, '(?m)^tool_call_timeout_sec\s*=.*$', 'tool_call_timeout_sec = 1260')
    } else { $body = "tool_call_timeout_sec = 1260`r`n" + $body }
    return $match.Groups[1].Value + $body
})
if ($updated -ne $content) {
    Copy-Item -LiteralPath $resolvedConfig -Destination ($resolvedConfig + '.confirmation-backup')
    [System.IO.File]::WriteAllText($resolvedConfig, $updated, [System.Text.UTF8Encoding]::new($false))
}
Write-Output 'CodeAssist MCP timeout set to 1260 seconds. Reload MCP or restart Codex to apply.'
