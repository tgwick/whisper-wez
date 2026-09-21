Set-StrictMode -Version Latest

function Get-WhisperWezVersion {
    [CmdletBinding()]
    param()
    '0.1.0'
}

function Resolve-Sqlite3Path {
    [CmdletBinding()]
    param([string]$RepoRoot = $PSScriptRoot)
    $bundled = Join-Path $RepoRoot 'sqlite3.exe'
    if (Test-Path $bundled) { return $bundled }
    $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "sqlite3.exe not found (bundled or on PATH). See README setup."
}

function Get-WhisperWezConfig {
    [CmdletBinding()]
    param([hashtable]$Overrides = @{})
    $root = $PSScriptRoot
    $config = @{
        DbPath       = Join-Path $env:APPDATA 'Wispr Flow\flow.sqlite'
        TargetApp    = 'wezterm-gui'
        PollMs       = 400
        PasteChunkChars = 40  # characters sent per SendInput batch during bracketed paste
        PasteDelayMs = 20   # pause between batches (ms); higher = safer against char drops, slower
        MaxRecentIds = 50
        StateFile    = Join-Path $root 'state.json'
        LogFile      = Join-Path $root 'whisperwez.log'
        Sqlite3Path  = $null   # resolved lazily by the runner to keep this pure/testable
    }
    foreach ($k in $Overrides.Keys) { $config[$k] = $Overrides[$k] }
    $config
}

function ConvertTo-SqlLiteral {
    param([string]$Value)
    "'" + ($Value -replace "'", "''") + "'"
}

function Read-NewTranscripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sqlite3Path,
        [Parameter(Mandatory)][string]$TargetApp,
        [Parameter(Mandatory)][string]$SinceTimestamp
    )
    if (-not (Test-Path $DbPath)) { throw "DB not found: $DbPath" }

    $app   = ConvertTo-SqlLiteral $TargetApp
    $since = ConvertTo-SqlLiteral $SinceTimestamp
    $sql = @"
SELECT transcriptEntityId AS Id, timestamp AS Timestamp,
       COALESCE(NULLIF(formattedText,''), NULLIF(asrText,'')) AS Text
FROM History
WHERE app = $app
  AND timestamp >= $since
  AND status IN ('formatted','raw_transcript')
  AND COALESCE(NULLIF(formattedText,''), NULLIF(asrText,'')) IS NOT NULL
ORDER BY timestamp ASC;
"@
    # Materialize rows into a variable before iterating: this makes the query execute
    # and get parsed exactly once, and keeps each row's shape explicit for the loop body.
    $dbRows = Invoke-Sqlite -Sqlite3Path $Sqlite3Path -DbPath $DbPath -Sql $sql
    $dbRows | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Timestamp = $_.Timestamp; Text = $_.Text }
    }
}

function ConvertTo-SqliteReadOnlyUri {
    # Builds a read-only sqlite3 "file:" URI from a filesystem path. Percent-encodes
    # the characters that are significant in a URI and realistically show up in a
    # real Windows path (Wispr's default DB lives under "...\Wispr Flow\flow.sqlite",
    # which contains a space) -- '%' is encoded first so an already-escaped path isn't
    # double-escaped, then space, '#', and '?'.
    param([string]$DbPath)
    $path = ($DbPath -replace '\\', '/')
    $path = $path.Replace('%', '%25').Replace('#', '%23').Replace('?', '%3F').Replace(' ', '%20')
    'file:' + $path + '?mode=ro'
}

function Invoke-Sqlite {
    # Runs a query against a read-only connection so Wispr's live DB is never locked/modified.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sqlite3Path,
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sql
    )
    $uri = ConvertTo-SqliteReadOnlyUri $DbPath

    # Merge stderr into the output (2>&1) instead of discarding it with 2>$null:
    # native stderr lines arrive as ErrorRecord objects mixed in with the plain-string
    # stdout lines, so they can be separated below. This lets a genuine sqlite3 failure
    # (missing table, malformed SQL, a corrupt/missing DB file) be told apart from a
    # legitimately empty result set and surfaced with the real error text instead of
    # being silently masked as "no rows".
    $raw = $Sql | & $Sqlite3Path -json -readonly $uri 2>&1
    $exitCode = $LASTEXITCODE
    $stdoutLines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $stderrText  = (@($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                        ForEach-Object { $_.ToString() })) -join "`n"

    if ($exitCode -ne 0) {
        throw "sqlite3 failed (exit code ${exitCode}) against '$DbPath': $stderrText"
    }

    # sqlite3 -json can split its JSON result array across multiple output lines (one
    # row fragment per line); join them back into a single string before parsing so
    # ConvertFrom-Json sees one complete document instead of per-line fragments that
    # don't individually parse.
    $joined = ($stdoutLines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($joined)) { return @() }

    # Parse, then wrap the result in @() as a *separate* statement. Wrapping @()
    # directly around an expression that itself invokes ConvertFrom-Json (e.g.
    # `@($x | ConvertFrom-Json)` or `@(ConvertFrom-Json $x)`) was empirically observed,
    # on this PowerShell 5.1 / sqlite3 3.53.4 combination, to silently truncate a
    # multi-row JSON array down to just its first element. Splitting the parse and the
    # array-normalization into two statements avoids that.
    $parsed = ConvertFrom-Json $joined
    $rows = @($parsed)   # normalizes a single-row result (which ConvertFrom-Json
                          # yields as a lone object, not a 1-element array) to an array
    $rows
}

function Get-DbMaxTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DbPath,
        [Parameter(Mandatory)][string]$Sqlite3Path
    )
    if (-not (Test-Path $DbPath)) { throw "DB not found: $DbPath" }
    $rows = Invoke-Sqlite -Sqlite3Path $Sqlite3Path -DbPath $DbPath `
                -Sql "SELECT COALESCE(MAX(timestamp),'') AS MaxTs FROM History;"
    if (-not $rows) { return '' }
    [string]$rows[0].MaxTs
}

function New-WhisperWezState {
    [CmdletBinding()]
    param([string]$Now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    [pscustomobject]@{ LastTimestamp = $Now; RecentIds = @() }
}

function Get-WhisperWezState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateFile)
    if (-not (Test-Path $StateFile)) { return $null }
    $o = Get-Content -Raw -Path $StateFile | ConvertFrom-Json
    [pscustomobject]@{ LastTimestamp = $o.LastTimestamp; RecentIds = @($o.RecentIds) }
}

function Save-WhisperWezState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateFile, [Parameter(Mandatory)]$State)
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

function Test-TranscriptProcessed {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Row)
    @($State.RecentIds) -contains $Row.Id
}

function Update-WhisperWezState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Row, [int]$MaxRecentIds = 50)
    $last = $State.LastTimestamp
    if ([string]::Compare($Row.Timestamp, $last) -gt 0) { $last = $Row.Timestamp }
    $ids = @($State.RecentIds) + $Row.Id
    if ($ids.Count -gt $MaxRecentIds) { $ids = $ids[($ids.Count - $MaxRecentIds)..($ids.Count - 1)] }
    [pscustomobject]@{ LastTimestamp = $last; RecentIds = $ids }
}

$script:User32 = @'
using System;
using System.Runtime.InteropServices;
public static class WWUser32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
'@
if (-not ('WWUser32' -as [type])) { Add-Type -TypeDefinition $script:User32 }

function Get-ForegroundProcessName {
    [CmdletBinding()]
    param()
    try {
        $h = [WWUser32]::GetForegroundWindow()
        if ($h -eq [IntPtr]::Zero) { return $null }
        [uint32]$procId = 0   # NOTE: do not name this $pid (read-only automatic var); type must match the out uint param
        [void][WWUser32]::GetWindowThreadProcessId($h, [ref]$procId)
        if ($procId -eq 0) { return $null }
        (Get-Process -Id $procId -ErrorAction Stop).ProcessName
    } catch { $null }
}

function Test-TargetFocused {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TargetApp)
    (Get-ForegroundProcessName) -eq $TargetApp
}

function Get-ClipboardTextSafe {
    [CmdletBinding()]
    param()
    try {
        $t = Get-Clipboard -Raw -ErrorAction Stop
        if ($null -eq $t) { '' } else { [string]$t }
    } catch { '' }
}

function Set-ClipboardTextSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try {
        if ([string]::IsNullOrEmpty($Text)) { Set-Clipboard -Value ' ' } # Set-Clipboard rejects empty
        else { Set-Clipboard -Value $Text }
        $true
    } catch { $false }
}

$script:SendInput = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
public static class __WWINJECT__ {
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion U; }
    [DllImport("user32.dll", SetLastError=true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    const uint INPUT_KEYBOARD = 1; const uint KEYEVENTF_KEYUP = 2; const uint KEYEVENTF_UNICODE = 4;
    const ushort VK_ESCAPE = 0x1B;
    // A Unicode "key" carries the UTF-16 code unit in wScan with wVk=0, so the character is
    // delivered literally regardless of keyboard layout. Surrogate pairs (e.g. emoji) work
    // because each half is its own code unit, sent as consecutive events.
    static INPUT UniKey(ushort codeUnit, bool up) {
        return new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT {
            wVk = 0, wScan = codeUnit,
            dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0) } } };
    }
    // A real virtual key (by VK code). Used for ESC: KEYEVENTF_UNICODE won't reliably deliver a
    // C0 control byte, but VK_ESCAPE presses send a genuine 0x1B to the terminal.
    static INPUT VkKey(ushort vk, bool up) {
        return new INPUT { type = INPUT_KEYBOARD, U = new InputUnion { ki = new KEYBDINPUT {
            wVk = vk, wScan = 0, dwFlags = (up ? KEYEVENTF_KEYUP : 0) } } };
    }
    public static int InputStructSize() { return Marshal.SizeOf(typeof(INPUT)); }
    // Delivers the text as a terminal BRACKETED PASTE -- ESC[200~ <text> ESC[201~. The markers put
    // the TUI (bash readline, Claude Code, ...) into paste-buffer mode: it accumulates the bytes as
    // pasted content instead of processing them as keystrokes, so they can't interleave with its
    // render/escape-sequence traffic (which corrupted per-character typing with stray chars). The
    // text is inline in the byte stream -- no clipboard -- so it also avoids the stale-clipboard
    // paste bug. ESC is a real VK_ESCAPE key; the rest Unicode.
    //
    // Pacing: the events are sent in batches of `chunkChars` characters per SendInput call, with a
    // `chunkDelayMs` pause between batches. This keeps the Windows input queue from being flooded
    // (the original cause of dropped characters) WITHOUT the old per-character sleep, which made a
    // long transcript take chars*delay ms to paste. Because bracketed paste buffers the bytes rather
    // than interpreting each as a keystroke, per-batch pacing is enough. Smaller chunkChars / larger
    // chunkDelayMs = safer against drops but slower; larger chunkChars / 0 delay = fastest.
    public static uint PasteText(string text, int chunkChars, int chunkDelayMs) {
        if (text == null) text = "";
        if (chunkChars < 1) chunkChars = 1;
        // Build the full event stream: ESC [200~ <text> ESC [201~, each char as a down+up pair.
        List<INPUT> events = new List<INPUT>((text.Length + 12) * 2);
        events.Add(VkKey(VK_ESCAPE, false)); events.Add(VkKey(VK_ESCAPE, true));
        foreach (char c in "[200~") { events.Add(UniKey((ushort)c, false)); events.Add(UniKey((ushort)c, true)); }
        foreach (char c in text)    { events.Add(UniKey((ushort)c, false)); events.Add(UniKey((ushort)c, true)); }
        events.Add(VkKey(VK_ESCAPE, false)); events.Add(VkKey(VK_ESCAPE, true));
        foreach (char c in "[201~") { events.Add(UniKey((ushort)c, false)); events.Add(UniKey((ushort)c, true)); }

        INPUT[] all = events.ToArray();
        int structSize = Marshal.SizeOf(typeof(INPUT));
        int batchEvents = chunkChars * 2;   // two events (down+up) per character
        uint total = 0;
        for (int i = 0; i < all.Length; i += batchEvents) {
            int n = Math.Min(batchEvents, all.Length - i);
            INPUT[] batch = new INPUT[n];
            Array.Copy(all, i, batch, 0, n);
            total += SendInput((uint)n, batch, structSize);
            if (chunkDelayMs > 0 && i + n < all.Length) Thread.Sleep(chunkDelayMs);
        }
        return total;
    }
}
'@
# Compile the helper under a name derived from a hash of its own source. A compiled .NET type
# cannot be redefined under the same name within one process, so editing this C# and re-running
# in a REUSED PowerShell session used to leave the old type loaded (symptom: 'Cannot find an
# overload' errors after a method signature changed). Hashing the source means any change yields a new type name that
# always compiles fresh, while a brand-new process simply compiles it once. String.GetHashCode
# (masked non-negative) is deterministic within a process and avoids crypto APIs that can throw
# on FIPS-locked machines; it only needs to be stable within a process, which it is.
$script:InjectTypeName = 'WWInject_' + ($script:SendInput.GetHashCode() -band 0x7FFFFFFF).ToString('x')
if (-not ($script:InjectTypeName -as [type])) {
    Add-Type -TypeDefinition ($script:SendInput -replace '__WWINJECT__', $script:InjectTypeName)
}
$script:InjectType = $script:InjectTypeName -as [type]

function Get-InjectType {
    # The compiled SendInput helper type (its name is source-hashed; see above). Exposed so
    # callers and tests reference the current type without hardcoding the hashed name.
    [CmdletBinding()]
    param()
    $script:InjectType
}

function ConvertTo-InjectableText {
    # Strip control characters before typing. The critical one is newline (\r/\n): typed
    # directly (there is no bracketed-paste wrapper) it acts as Enter and could run a command
    # -- exactly the auto-execute risk the design forbids. Tabs and other C0 controls (and DEL)
    # are removed too; ordinary printable text, accents and emoji pass through untouched.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    ($Text.ToCharArray() | Where-Object { [int]$_ -ge 32 -and [int]$_ -ne 127 }) -join ''
}

function Send-BracketedPaste {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$ChunkChars = 40,  # characters per SendInput batch
        [int]$DelayMs = 20      # pause between batches; paces the paste so Claude Code doesn't drop characters
    )
    if ([string]::IsNullOrEmpty($Text)) { return }
    $type = $script:InjectType
    $sent = $type::PasteText($Text, $ChunkChars, $DelayMs)
    if ($sent -eq 0) { throw "SendInput injected 0 events (Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
}

function Invoke-Injection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$DryRun
    )
    $focused = Test-TargetFocused -TargetApp $Config.TargetApp

    if ($DryRun) {
        return [pscustomobject]@{ Action = 'dryrun'; Focused = $focused }
    }

    if (-not $focused) {
        # WezTerm isn't focused, so we must not type into whatever is. Leave the transcript on
        # the clipboard for a manual Ctrl+Shift+V and skip injection (the focus guard).
        [void](Set-ClipboardTextSafe -Text $Text)
        return [pscustomobject]@{ Action = 'clipboard-only'; Focused = $false }
    }

    # Inject the transcript as a terminal bracketed paste (see Send-BracketedPaste) -- one block,
    # inline in the byte stream. No clipboard (so nothing for Wispr's clipboard save/restore to
    # race), and not a keystroke stream (so it can't interleave with a TUI's escape-sequence
    # traffic the way per-character typing did). Strip control chars first so a stray newline
    # can't act as Enter and run a command.
    $injectable = ConvertTo-InjectableText -Text $Text
    Send-BracketedPaste -Text $injectable -ChunkChars $Config.PasteChunkChars -DelayMs $Config.PasteDelayMs
    [pscustomobject]@{ Action = 'pasted'; Focused = $true }
}

function Write-WhisperWezLog {
    [CmdletBinding()]
    param(
        [string]$LogFile,
        [string]$Message = '',
        [string]$Level = 'INFO',
        [int]$MaxBytes = 5MB
    )
    if ([string]::IsNullOrEmpty($LogFile)) { return }  # can't log without a path; return silently rather than throw
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt $MaxBytes)) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
        }
        $line = "{0} [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }  # logging must never crash the loop
}

function Start-WhisperWez {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$DryRun,
        [switch]$Once
    )
    $state = $null

    do {
        try {
            if ($null -eq $state) {
                $existing = Get-WhisperWezState -StateFile $Config.StateFile
                if ($null -ne $existing) {
                    $state = $existing
                } else {
                    # Seed from the DB's own clock/format (UTC) so timestamp comparisons are
                    # apples-to-apples. This must happen INSIDE the try: Get-DbMaxTimestamp
                    # throws on a real DB failure (missing DB/table, corrupt file), and a
                    # startup DB error should be logged and retried next tick, not crash the loop.
                    $seed = Get-DbMaxTimestamp -DbPath $Config.DbPath -Sqlite3Path $Config.Sqlite3Path
                    $state = New-WhisperWezState -Now $seed
                    Save-WhisperWezState -StateFile $Config.StateFile -State $state
                    Write-WhisperWezLog -LogFile $Config.LogFile -Message "Initialized high-water mark at '$seed'"
                }
            }

            $rows = Read-NewTranscripts -DbPath $Config.DbPath -Sqlite3Path $Config.Sqlite3Path `
                        -TargetApp $Config.TargetApp -SinceTimestamp $state.LastTimestamp
            foreach ($row in @($rows)) {
                if (Test-TranscriptProcessed -State $state -Row $row) { continue }
                $result = Invoke-Injection -Text $row.Text -Config $Config -DryRun:$DryRun
                $state = Update-WhisperWezState -State $state -Row $row -MaxRecentIds $Config.MaxRecentIds
                Save-WhisperWezState -StateFile $Config.StateFile -State $state
                Write-WhisperWezLog -LogFile $Config.LogFile `
                    -Message ("{0} chars -> {1} (focused={2}) id={3}" -f $row.Text.Length, $result.Action, $result.Focused, $row.Id)
            }
        } catch {
            Write-WhisperWezLog -LogFile $Config.LogFile -Level 'ERROR' -Message $_.Exception.Message
        }
        if (-not $Once) { Start-Sleep -Milliseconds $Config.PollMs }
    } while (-not $Once)
}

Export-ModuleMember -Function *
