BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\WhisperWez.psm1'
    Import-Module $script:ModulePath -Force
}

Describe 'Get-WhisperWezVersion' {
    It 'returns a semantic version string' {
        Get-WhisperWezVersion | Should -Match '^\d+\.\d+\.\d+$'
    }
}

Describe 'Get-WhisperWezConfig' {
    It 'provides expected defaults' {
        $c = Get-WhisperWezConfig
        $c.TargetApp              | Should -Be 'wezterm-gui'
        $c.PollMs                 | Should -Be 400
        $c.RestoreClipboard       | Should -BeTrue
        $c.MaxRecentIds           | Should -Be 50
        $c.ClipboardRestoreDelayMs| Should -Be 300
        $c.DbPath                 | Should -Match 'flow\.sqlite$'
    }
    It 'applies overrides' {
        $c = Get-WhisperWezConfig -Overrides @{ PollMs = 100; TargetApp = 'x' }
        $c.PollMs    | Should -Be 100
        $c.TargetApp | Should -Be 'x'
    }
}

Describe 'Resolve-Sqlite3Path' {
    It 'prefers a bundled sqlite3.exe in the repo root' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        Set-Content -Path (Join-Path $tmp 'sqlite3.exe') -Value 'stub'
        Resolve-Sqlite3Path -RepoRoot $tmp | Should -Be (Join-Path $tmp 'sqlite3.exe')
        Remove-Item $tmp -Recurse -Force
    }
}

Describe 'Read-NewTranscripts' {
    BeforeAll {
        $script:sqlite = Resolve-Sqlite3Path -RepoRoot (Join-Path $PSScriptRoot '..')
        $script:db = Join-Path ([IO.Path]::GetTempPath()) ("ww_" + [guid]::NewGuid() + ".sqlite")
        # Timestamps mirror the real DB shape: UTC, milliseconds, "+00:00" suffix.
        $ddl = @'
CREATE TABLE History (transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, app TEXT, formattedText TEXT, asrText TEXT, status TEXT);
INSERT INTO History VALUES ('id1','2026-09-02 10:00:00.100 +00:00','wezterm-gui','hello world','hello raw','formatted');
INSERT INTO History VALUES ('id2','2026-09-02 10:00:01.100 +00:00','wezterm-gui','','fallback text','formatted');
INSERT INTO History VALUES ('id3','2026-09-02 10:00:02.100 +00:00','wezterm-gui','','','formatted');
INSERT INTO History VALUES ('id4','2026-09-02 10:00:03.100 +00:00','chrome','other app','other','formatted');
INSERT INTO History VALUES ('id5','2026-09-02 09:00:00.100 +00:00','wezterm-gui','too old','old','formatted');
INSERT INTO History VALUES ('id6','2026-09-02 10:00:04.100 +00:00','wezterm-gui','line1
line2','multi','formatted');
INSERT INTO History VALUES ('id7','2026-09-02 10:00:05.100 +00:00','wezterm-gui','half baked','partial','processing');
INSERT INTO History VALUES ('id8','2026-09-02 10:00:06.100 +00:00','wezterm-gui','raw only','raw asr','raw_transcript');
'@
        $ddl | & $script:sqlite $script:db
        $script:since = '2026-09-02 10:00:00.100 +00:00'
    }
    AfterAll { Remove-Item $script:db -Force -ErrorAction SilentlyContinue }

    It 'returns only new, finalized, wezterm rows in ascending order' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | ForEach-Object Id) | Should -Be @('id1','id2','id6','id8')
    }
    It 'applies asrText fallback when formattedText is empty' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id2').Text | Should -Be 'fallback text'
    }
    It 'excludes rows where both text columns are empty' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id3') | Should -BeNullOrEmpty
    }
    It 'excludes non-final (processing) rows' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id7') | Should -BeNullOrEmpty
    }
    It 'includes raw_transcript rows' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id8').Text | Should -Be 'raw only'
    }
    It 'preserves multi-line text' {
        $rows = Read-NewTranscripts -DbPath $script:db -Sqlite3Path $script:sqlite -TargetApp 'wezterm-gui' -SinceTimestamp $script:since
        ($rows | Where-Object Id -eq 'id6').Text | Should -Be "line1`nline2"
    }
}

Describe 'Get-DbMaxTimestamp' {
    BeforeAll {
        $script:sqlite2 = Resolve-Sqlite3Path -RepoRoot (Join-Path $PSScriptRoot '..')
        $script:db2 = Join-Path ([IO.Path]::GetTempPath()) ("ww_max_" + [guid]::NewGuid() + ".sqlite")
        @'
CREATE TABLE History (transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, app TEXT, formattedText TEXT, asrText TEXT, status TEXT);
INSERT INTO History VALUES ('a','2026-09-02 10:00:00.100 +00:00','chrome','x','x','formatted');
INSERT INTO History VALUES ('b','2026-09-02 10:00:06.100 +00:00','wezterm-gui','y','y','formatted');
'@ | & $script:sqlite2 $script:db2
    }
    AfterAll { Remove-Item $script:db2 -Force -ErrorAction SilentlyContinue }

    It 'returns the maximum timestamp across all rows' {
        Get-DbMaxTimestamp -DbPath $script:db2 -Sqlite3Path $script:sqlite2 | Should -Be '2026-09-02 10:00:06.100 +00:00'
    }
    It 'returns empty string for an empty table' {
        $empty = Join-Path ([IO.Path]::GetTempPath()) ("ww_empty_" + [guid]::NewGuid() + ".sqlite")
        'CREATE TABLE History (transcriptEntityId TEXT, timestamp TEXT);' | & $script:sqlite2 $empty
        Get-DbMaxTimestamp -DbPath $empty -Sqlite3Path $script:sqlite2 | Should -Be ''
        Remove-Item $empty -Force
    }
}

Describe 'Invoke-Sqlite' {
    BeforeAll {
        $script:sqlite3v = Resolve-Sqlite3Path -RepoRoot (Join-Path $PSScriptRoot '..')
        $script:db3 = Join-Path ([IO.Path]::GetTempPath()) ("ww_multi_" + [guid]::NewGuid() + ".sqlite")
        $rowInserts = 1..15 | ForEach-Object { "INSERT INTO t VALUES ($_, 'row$_');" }
        $ddl3 = "CREATE TABLE t (n INTEGER, label TEXT);`n" + ($rowInserts -join "`n")
        $ddl3 | & $script:sqlite3v $script:db3
    }
    AfterAll { Remove-Item $script:db3 -Force -ErrorAction SilentlyContinue }

    It 'round-trips every row when sqlite3 -json output spans multiple lines' {
        $result = Invoke-Sqlite -Sqlite3Path $script:sqlite3v -DbPath $script:db3 -Sql 'SELECT n, label FROM t ORDER BY n;'
        @($result).Count | Should -Be 15
        ($result | ForEach-Object label) | Should -Be (1..15 | ForEach-Object { "row$_" })
    }

    It 'throws with the sqlite3 error text when the query references a table that does not exist' {
        { Invoke-Sqlite -Sqlite3Path $script:sqlite3v -DbPath $script:db3 -Sql 'SELECT * FROM NoSuchTable;' } |
            Should -Throw '*no such table*'
    }

    It 'throws when the SQL is malformed' {
        { Invoke-Sqlite -Sqlite3Path $script:sqlite3v -DbPath $script:db3 -Sql 'SELECT FROM FROM;;;' } | Should -Throw
    }

    It 'returns an empty array (not an error) for a query that legitimately matches no rows' {
        $result = Invoke-Sqlite -Sqlite3Path $script:sqlite3v -DbPath $script:db3 -Sql 'SELECT n, label FROM t WHERE n > 999;'
        @($result).Count | Should -Be 0
    }
}

Describe 'Read-NewTranscripts with a space in the DB path' {
    BeforeAll {
        $script:sqliteSp = Resolve-Sqlite3Path -RepoRoot (Join-Path $PSScriptRoot '..')
        $script:dirSp = Join-Path ([IO.Path]::GetTempPath()) ("ww space " + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:dirSp | Out-Null
        $script:dbSp = Join-Path $script:dirSp 'flow.sqlite'
        $ddlSp = @'
CREATE TABLE History (transcriptEntityId TEXT PRIMARY KEY, timestamp TEXT, app TEXT, formattedText TEXT, asrText TEXT, status TEXT);
INSERT INTO History VALUES ('sp1','2026-09-02 10:00:00.100 +00:00','wezterm-gui','space path works','raw','formatted');
'@
        $ddlSp | & $script:sqliteSp $script:dbSp
    }
    AfterAll { Remove-Item $script:dirSp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads rows correctly when the DB directory name contains a space' {
        $rows = Read-NewTranscripts -DbPath $script:dbSp -Sqlite3Path $script:sqliteSp -TargetApp 'wezterm-gui' -SinceTimestamp '2026-09-02 00:00:00.000 +00:00'
        ($rows | ForEach-Object Id) | Should -Be @('sp1')
        ($rows | Where-Object Id -eq 'sp1').Text | Should -Be 'space path works'
    }
}

Describe 'WhisperWez state' {
    It 'New-WhisperWezState starts empty at the given time' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $s.LastTimestamp | Should -Be '2026-09-02 12:00:00'
        @($s.RecentIds).Count | Should -Be 0
    }
    It 'Get-WhisperWezState returns null when file is absent' {
        Get-WhisperWezState -StateFile (Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())) | Should -BeNullOrEmpty
    }
    It 'Save/Get round-trips' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        Save-WhisperWezState -StateFile $f -State $s
        (Get-WhisperWezState -StateFile $f).LastTimestamp | Should -Be '2026-09-02 12:00:00'
        Remove-Item $f -Force
    }
    It 'Update advances timestamp and records id' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $row = [pscustomobject]@{ Id='a'; Timestamp='2026-09-02 12:00:05'; Text='x' }
        $s2 = Update-WhisperWezState -State $s -Row $row
        $s2.LastTimestamp | Should -Be '2026-09-02 12:00:05'
        $s2.RecentIds | Should -Contain 'a'
    }
    It 'Update keeps the larger timestamp when row is older' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:10'
        $row = [pscustomobject]@{ Id='b'; Timestamp='2026-09-02 12:00:05'; Text='x' }
        (Update-WhisperWezState -State $s -Row $row).LastTimestamp | Should -Be '2026-09-02 12:00:10'
    }
    It 'Update trims RecentIds to MaxRecentIds' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        1..5 | ForEach-Object {
            $s = Update-WhisperWezState -State $s -Row ([pscustomobject]@{ Id="id$_"; Timestamp='2026-09-02 12:00:00'; Text='x' }) -MaxRecentIds 3
        }
        @($s.RecentIds).Count | Should -Be 3
        $s.RecentIds | Should -Be @('id3','id4','id5')
    }
    It 'Test-TranscriptProcessed detects a known id' {
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $s = Update-WhisperWezState -State $s -Row ([pscustomobject]@{ Id='seen'; Timestamp='2026-09-02 12:00:00'; Text='x' })
        Test-TranscriptProcessed -State $s -Row ([pscustomobject]@{ Id='seen' })  | Should -BeTrue
        Test-TranscriptProcessed -State $s -Row ([pscustomobject]@{ Id='new' })   | Should -BeFalse
    }
    It 'Save/Get round-trips a 1-element RecentIds without collapsing it to a scalar' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $s = Update-WhisperWezState -State $s -Row ([pscustomobject]@{ Id='only1'; Timestamp='2026-09-02 12:00:01'; Text='x' })
        Save-WhisperWezState -StateFile $f -State $s
        $reloaded = Get-WhisperWezState -StateFile $f
        # Assert the raw returned property is actually an array (not a scalar the JSON
        # round-trip collapsed it to) before any test-side @() re-normalization would mask it.
        $reloaded.RecentIds -is [array] | Should -BeTrue
        @($reloaded.RecentIds).Count | Should -Be 1
        $reloaded.RecentIds | Should -Contain 'only1'
        Test-TranscriptProcessed -State $reloaded -Row ([pscustomobject]@{ Id='only1' }) | Should -BeTrue
        Remove-Item $f -Force
    }
    It 'Save/Get round-trips a multi-element RecentIds' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.json')
        $s = New-WhisperWezState -Now '2026-09-02 12:00:00'
        $s = Update-WhisperWezState -State $s -Row ([pscustomobject]@{ Id='m1'; Timestamp='2026-09-02 12:00:01'; Text='x' })
        $s = Update-WhisperWezState -State $s -Row ([pscustomobject]@{ Id='m2'; Timestamp='2026-09-02 12:00:02'; Text='x' })
        Save-WhisperWezState -StateFile $f -State $s
        $reloaded = Get-WhisperWezState -StateFile $f
        @($reloaded.RecentIds).Count | Should -Be 2
        $reloaded.RecentIds | Should -Contain 'm1'
        $reloaded.RecentIds | Should -Contain 'm2'
        Test-TranscriptProcessed -State $reloaded -Row ([pscustomobject]@{ Id='m1' }) | Should -BeTrue
        Test-TranscriptProcessed -State $reloaded -Row ([pscustomobject]@{ Id='m2' }) | Should -BeTrue
        Remove-Item $f -Force
    }
}

Describe 'Test-TargetFocused' {
    It 'is true when foreground matches target' {
        Mock -ModuleName WhisperWez Get-ForegroundProcessName { 'wezterm-gui' }
        Test-TargetFocused -TargetApp 'wezterm-gui' | Should -BeTrue
    }
    It 'is false when foreground differs' {
        Mock -ModuleName WhisperWez Get-ForegroundProcessName { 'chrome' }
        Test-TargetFocused -TargetApp 'wezterm-gui' | Should -BeFalse
    }
    It 'is false when foreground is unknown' {
        Mock -ModuleName WhisperWez Get-ForegroundProcessName { $null }
        Test-TargetFocused -TargetApp 'wezterm-gui' | Should -BeFalse
    }
}

Describe 'Get-ForegroundProcessName (smoke)' {
    It 'returns a string or null without throwing' {
        { Get-ForegroundProcessName } | Should -Not -Throw
    }
}

Describe 'Clipboard primitives' {
    It 'round-trips clipboard text' {
        $marker = 'WW_TEST_' + [guid]::NewGuid()
        (Set-ClipboardTextSafe -Text $marker) | Should -BeTrue
        Get-ClipboardTextSafe | Should -Be $marker
    }
    It 'Set-ClipboardTextSafe handles empty string' {
        (Set-ClipboardTextSafe -Text '') | Should -BeTrue
    }
}

Describe 'SendInput INPUT struct ABI size' {
    It 'INPUT marshals to the native size for this architecture' {
        $expected = if ([Environment]::Is64BitProcess) { 40 } else { 28 }
        [WWInput]::InputStructSize() | Should -Be $expected
    }
}

Describe 'Invoke-Injection' {
    BeforeEach {
        $script:cfg = Get-WhisperWezConfig -Overrides @{ RestoreClipboard = $true; ClipboardRestoreDelayMs = 0 }
        Mock -ModuleName WhisperWez Get-ClipboardTextSafe { 'PREV' }
        Mock -ModuleName WhisperWez Set-ClipboardTextSafe { $true }
        Mock -ModuleName WhisperWez Send-CtrlV {}
        Mock -ModuleName WhisperWez Start-Sleep {}
    }
    It 'pastes and restores when WezTerm is focused' {
        Mock -ModuleName WhisperWez Test-TargetFocused { $true }
        $r = Invoke-Injection -Text 'hello' -Config $script:cfg
        $r.Action  | Should -Be 'pasted'
        $r.Focused | Should -BeTrue
        Should -Invoke -ModuleName WhisperWez Send-CtrlV -Times 1 -Exactly
        Should -Invoke -ModuleName WhisperWez Set-ClipboardTextSafe -Times 2 -Exactly  # set text, then restore
    }
    It 'sets clipboard only when not focused' {
        Mock -ModuleName WhisperWez Test-TargetFocused { $false }
        $r = Invoke-Injection -Text 'hello' -Config $script:cfg
        $r.Action | Should -Be 'clipboard-only'
        Should -Invoke -ModuleName WhisperWez Send-CtrlV -Times 0 -Exactly
        Should -Invoke -ModuleName WhisperWez Set-ClipboardTextSafe -Times 1 -Exactly
    }
    It 'does nothing to the OS in DryRun' {
        Mock -ModuleName WhisperWez Test-TargetFocused { $true }
        $r = Invoke-Injection -Text 'hello' -Config $script:cfg -DryRun
        $r.Action | Should -Be 'dryrun'
        Should -Invoke -ModuleName WhisperWez Send-CtrlV -Times 0 -Exactly
        Should -Invoke -ModuleName WhisperWez Set-ClipboardTextSafe -Times 0 -Exactly
    }
}

Describe 'Write-WhisperWezLog' {
    It 'appends a timestamped, leveled line' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.log')
        Write-WhisperWezLog -LogFile $f -Message 'hello' -Level 'INFO'
        (Get-Content $f) | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[INFO\] hello$'
        Remove-Item $f -Force
    }
    It 'rolls the file when oversized' {
        $f = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.log')
        Set-Content -Path $f -Value ('x' * 10)
        Write-WhisperWezLog -LogFile $f -Message 'after' -MaxBytes 5
        Test-Path "$f.1" | Should -BeTrue
        Remove-Item $f, "$f.1" -Force -ErrorAction SilentlyContinue
    }
}
