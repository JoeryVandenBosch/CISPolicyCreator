[CmdletBinding()]
param(
    [string]$MarkdownPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\FAIL-CLOSED-POLICY.md'),
    [string]$DocxPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\CISPolicyCreator_Fail_Closed_Mapping_Policy.docx')
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression
$markdown=(Resolve-Path -LiteralPath $MarkdownPath).Path
$docx=(Resolve-Path -LiteralPath $DocxPath).Path
$lines=Get-Content -LiteralPath $markdown
$body=[Text.StringBuilder]::new()
$inCode=$false
foreach($line in $lines){
    if($line -match '^```'){ $inCode=-not $inCode; continue }
    $style=$null; $text=$line
    if($line -match '^(#{1,3})\s+(.+)$'){
        $style='Heading'+$Matches[1].Length
        $text=$Matches[2]
    } elseif($line -match '^[-*]\s+(.+)$'){
        $text='• '+$Matches[1]
    }
    $escaped=[Security.SecurityElement]::Escape($text)
    [void]$body.Append('<w:p>')
    if($style){ [void]$body.Append(('<w:pPr><w:pStyle w:val="{0}"/></w:pPr>' -f $style)) }
    if($escaped){
        [void]$body.Append('<w:r>')
        if($inCode){ [void]$body.Append('<w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/></w:rPr>') }
        [void]$body.Append('<w:t xml:space="preserve">'+$escaped+'</w:t></w:r>')
    }
    [void]$body.Append('</w:p>')
}
$document='<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'+
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'+
    '<w:body>'+$body.ToString()+'<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>'
$archive=[IO.Compression.ZipFile]::Open($docx,[IO.Compression.ZipArchiveMode]::Update)
try{
    $old=$archive.GetEntry('word/document.xml')
    if(-not $old){ throw 'DOCX template has no word/document.xml entry.' }
    $old.Delete()
    $entry=$archive.CreateEntry('word/document.xml',[IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
    $stream=$entry.Open()
    $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
    try{ $writer.Write($document) } finally { $writer.Dispose(); $stream.Dispose() }
} finally { $archive.Dispose() }
Write-Host "Updated Word companion from $markdown"
