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
