BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '..\WhisperWez.psm1'
    Import-Module $script:ModulePath -Force
}

Describe 'Get-WhisperWezVersion' {
    It 'returns a semantic version string' {
        Get-WhisperWezVersion | Should -Match '^\d+\.\d+\.\d+$'
    }
}
