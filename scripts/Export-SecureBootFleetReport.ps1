[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputDirectory,

    [Parameter(Mandatory = $false)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [string]$HtmlPath
)

function Get-SecureBootReportValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return ''
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($property -and $null -ne $property.Value) {
        return [string]$property.Value
    }

    return ''
}

function ConvertTo-SecureBootHtmlText {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Export-SecureBootFleetReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputDirectory,

        [Parameter(Mandatory = $true)]
        [string]$CsvPath,

        [Parameter(Mandatory = $true)]
        [string]$HtmlPath
    )

    $records = @(
        Get-ChildItem -LiteralPath $InputDirectory -Filter '*.json' -File |
            Sort-Object Name |
            ForEach-Object {
                $json = $null
                $invalidInput = $false

                try {
                    $rawJson = Get-Content -LiteralPath $_.FullName -Raw
                    $json = ConvertFrom-Json -InputObject $rawJson -ErrorAction Stop
                }
                catch {
                    $invalidInput = $true
                }

                if ($invalidInput) {
                    [pscustomobject][ordered]@{
                        TenantName = ''
                        CustomerName = ''
                        Status = 'INVALID_INPUT'
                        DeviceName = ''
                        TimestampUtc = ''
                        ReasonCode = 'INVALID_INPUT'
                        Recommendation = 'Provide a valid JSON result file before including this device in the fleet report.'
                        SourceFile = $_.Name
                    }
                }
                else {
                    [pscustomobject][ordered]@{
                        TenantName = Get-SecureBootReportValue -Object $json -Name 'TenantName'
                        CustomerName = Get-SecureBootReportValue -Object $json -Name 'CustomerName'
                        Status = Get-SecureBootReportValue -Object $json -Name 'Status'
                        DeviceName = Get-SecureBootReportValue -Object $json -Name 'DeviceName'
                        TimestampUtc = Get-SecureBootReportValue -Object $json -Name 'TimestampUtc'
                        ReasonCode = Get-SecureBootReportValue -Object $json -Name 'ReasonCode'
                        Recommendation = Get-SecureBootReportValue -Object $json -Name 'Recommendation'
                        SourceFile = $_.Name
                    }
                }
            } |
            Sort-Object TenantName, CustomerName, Status, DeviceName, SourceFile
    )

    $records | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

    $html = New-Object System.Collections.Generic.List[string]
    $html.Add('<!doctype html>')
    $html.Add('<html>')
    $html.Add('<head>')
    $html.Add('<meta charset="utf-8" />')
    $html.Add('<title>Secure Boot Fleet Report</title>')
    $html.Add('</head>')
    $html.Add('<body>')
    $html.Add('<h1>Secure Boot Fleet Report</h1>')

    foreach ($tenant in @($records | Select-Object -ExpandProperty TenantName -Unique)) {
        $html.Add("<h2>$(ConvertTo-SecureBootHtmlText $tenant)</h2>")

        foreach ($customer in @($records | Where-Object { $_.TenantName -eq $tenant } | Select-Object -ExpandProperty CustomerName -Unique)) {
            $html.Add("<h3>$(ConvertTo-SecureBootHtmlText $customer)</h3>")

            foreach ($status in @($records | Where-Object { $_.TenantName -eq $tenant -and $_.CustomerName -eq $customer } | Select-Object -ExpandProperty Status -Unique)) {
                $statusRecords = @($records | Where-Object { $_.TenantName -eq $tenant -and $_.CustomerName -eq $customer -and $_.Status -eq $status })
                $html.Add("<h4>$(ConvertTo-SecureBootHtmlText $status)</h4>")
                $html.Add('<table>')
                $html.Add('<thead><tr><th>DeviceName</th><th>TimestampUtc</th><th>ReasonCode</th><th>Recommendation</th><th>SourceFile</th></tr></thead>')
                $html.Add('<tbody>')

                foreach ($record in $statusRecords) {
                    $html.Add("<tr><td>$(ConvertTo-SecureBootHtmlText $record.DeviceName)</td><td>$(ConvertTo-SecureBootHtmlText $record.TimestampUtc)</td><td>$(ConvertTo-SecureBootHtmlText $record.ReasonCode)</td><td>$(ConvertTo-SecureBootHtmlText $record.Recommendation)</td><td>$(ConvertTo-SecureBootHtmlText $record.SourceFile)</td></tr>")
                }

                $html.Add('</tbody>')
                $html.Add('</table>')
            }
        }
    }

    $html.Add('</body>')
    $html.Add('</html>')
    Set-Content -LiteralPath $HtmlPath -Value $html.ToArray() -Encoding UTF8

    return [pscustomobject][ordered]@{
        RecordCount = $records.Count
        CsvPath = $CsvPath
        HtmlPath = $HtmlPath
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Export-SecureBootFleetReport -InputDirectory $InputDirectory -CsvPath $CsvPath -HtmlPath $HtmlPath
    Write-Output ($result | ConvertTo-Json -Depth 4 -Compress)
}
