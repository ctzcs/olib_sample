$ErrorActionPreference = 'Stop'
$bookDxc = Get-Command dxc -ErrorAction Stop
$bookOut = Join-Path $PSScriptRoot 'Compiled'
New-Item -ItemType Directory -Force -Path $bookOut | Out-Null
foreach ($bookStage in @(@('vertex', 'vs_6_0', 'vertex_main'), @('fragment', 'ps_6_0', 'fragment_main'))) {
    & $bookDxc.Source -spirv -T $bookStage[1] -E $bookStage[2] -Fo (Join-Path $bookOut "Book.$($bookStage[0]).spv") (Join-Path $PSScriptRoot 'Book.hlsl')
    if ($LASTEXITCODE -ne 0) { throw 'Book SPIR-V compilation failed' }
    & $bookDxc.Source -T $bookStage[1] -E $bookStage[2] -Fo (Join-Path $bookOut "Book.$($bookStage[0]).dxil") (Join-Path $PSScriptRoot 'Book.hlsl')
    if ($LASTEXITCODE -ne 0) { throw 'Book DXIL compilation failed' }
}
