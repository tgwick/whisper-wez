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
